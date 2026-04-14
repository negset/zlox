const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const compiler = @import("compiler.zig");
const Compiler = @import("compiler.zig").Compiler;
const GC = @import("memory.zig").GC;
const Obj = @import("object.zig").Obj;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjString = @import("object.zig").ObjString;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const config = @import("config");

const frames_max = 64;
const stack_max = frames_max * Compiler.u8_count;

pub const RuntimeError = error{InvalidOperand} || Allocator.Error;
pub const Error = RuntimeError || compiler.Error;

const CallFrame = struct {
    function: *const ObjFunction,
    ip: usize,
    slots: [*]Value,

    pub fn readByte(self: *CallFrame) u8 {
        defer self.ip += 1;
        return self.function.chunk.code.items[self.ip];
    }

    pub fn readShort(self: *CallFrame) u16 {
        defer self.ip += 2;
        const buf = self.function.chunk.code.items[self.ip .. self.ip + 2];
        return std.mem.readInt(u16, buf[0..2], .big);
    }

    pub fn readConstant(self: *CallFrame) Value {
        return self.function.chunk.constants.items[self.readByte()];
    }

    pub fn readString(self: *CallFrame) *const ObjString {
        return self.readConstant().obj.as(ObjString);
    }
};

pub const VM = struct {
    frames: [frames_max]CallFrame,
    frame_count: usize,
    stack: std.ArrayList(Value),
    gc: GC,

    pub fn init(allocator: Allocator) Allocator.Error!VM {
        return .{
            .frames = undefined,
            .frame_count = 0,
            .stack = try .initCapacity(allocator, stack_max),
            .gc = .init,
        };
    }

    pub fn deinit(self: *VM, allocator: Allocator) void {
        self.stack.deinit(allocator);
        self.gc.deinit(allocator);
    }

    fn resetStack(self: *VM) void {
        self.stack.shrinkRetainingCapacity(0);
        self.frame_count = 0;
    }

    fn runtimeError(self: *VM, err: RuntimeError, comptime fmt: []const u8, args: anytype) RuntimeError {
        const frame = &self.frames[self.frame_count - 1];
        const line = frame.function.chunk.lines.items[frame.ip - 1];
        std.debug.print("[line {d}] {s} (runtime): ", .{ line, @errorName(err) });
        std.debug.print(fmt ++ "\n", args);

        self.resetStack();
        return err;
    }

    fn push(self: *VM, value: Value) void {
        self.stack.appendBounded(value) catch @panic("Stack overflow.");
    }

    fn pop(self: *VM) Value {
        return self.stack.pop() orelse @panic("Stack underflow.");
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    fn concatenate(self: *VM, allocator: Allocator) Allocator.Error!void {
        const b = self.pop().obj.as(ObjString).string;
        const a = self.pop().obj.as(ObjString).string;
        const string = try std.mem.concat(allocator, u8, &.{ a, b });

        const result = try ObjString.createByTake(allocator, &self.gc, string);
        self.push(Value{ .obj = &result.obj });
    }

    fn run(self: *VM, allocator: Allocator) RuntimeError!void {
        const frame = &self.frames[self.frame_count - 1];

        while (true) {
            if (comptime config.trace_execution) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ ", .{});
                    slot.print();
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});
                _ = debug.disassembleInstruction(&frame.function.chunk, frame.ip);
            }

            const instruction: OpCode = @enumFromInt(frame.readByte());
            switch (instruction) {
                .constant => self.push(frame.readConstant()),
                .nil => self.push(.{ .nil = {} }),
                .true => self.push(.{ .bool = true }),
                .false => self.push(.{ .bool = false }),
                .pop => _ = self.pop(),
                .get_local => {
                    const slot = frame.readByte();
                    self.push(frame.slots[slot]);
                },
                .set_local => {
                    const slot = frame.readByte();
                    frame.slots[slot] = self.peek(0);
                },
                .get_global => {
                    const name = frame.readString();
                    if (self.gc.globals.get(name)) |value| {
                        self.push(value);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Undefined variable '{s}'.",
                        .{name.string},
                    );
                },
                .define_global => {
                    const name = frame.readString();
                    // To avoid GC, pop value after put it to the table.
                    try self.gc.globals.put(allocator, name, self.peek(0));
                    _ = self.pop();
                },
                .set_global => {
                    const name = frame.readString();
                    if (self.gc.globals.getPtr(name)) |ptr| {
                        // If exists, overwrite it.
                        ptr.* = self.peek(0);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Undefined variable '{s}'.",
                        .{name.string},
                    );
                },
                .equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(.{ .bool = a.equals(b) });
                },
                .greater => try self.binaryOp(.greater),
                .less => try self.binaryOp(.less),
                .add => {
                    if (self.peek(0).isObjType(.string) and self.peek(1).isObjType(.string)) {
                        try self.concatenate(allocator);
                    } else if (self.peek(0) == .number and self.peek(1) == .number) {
                        try self.binaryOp(.add);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Operands must be two numbers or two strings.",
                        .{},
                    );
                },
                .subtract => try self.binaryOp(.subtract),
                .multiply => try self.binaryOp(.multiply),
                .divide => try self.binaryOp(.divide),
                .not => self.push(.{ .bool = self.pop().isFalsey() }),
                .negate => switch (self.peek(0)) {
                    .number => self.push(.{ .number = -(self.pop().number) }),
                    else => return self.runtimeError(error.InvalidOperand, "Operand must be a number.", .{}),
                },
                .print => {
                    self.pop().print();
                    std.debug.print("\n", .{});
                },
                .jump => {
                    const distance = frame.readShort();
                    frame.ip += distance;
                },
                .jump_if_false => {
                    const distance = frame.readShort();
                    if (self.peek(0).isFalsey()) frame.ip += distance;
                },
                .loop => {
                    const distance = frame.readShort();
                    frame.ip -= distance;
                },
                .@"return" => {
                    // Exit interpreter.
                    return;
                },
            }
        }
    }

    fn binaryOp(self: *VM, comptime instruction: OpCode) RuntimeError!void {
        if (self.peek(0) != .number or self.peek(1) != .number) {
            return self.runtimeError(error.InvalidOperand, "Operands must be numbers.", .{});
        }
        const b = self.pop().number;
        const a = self.pop().number;
        self.push(switch (instruction) {
            .add => .{ .number = a + b },
            .subtract => .{ .number = a - b },
            .multiply => .{ .number = a * b },
            .divide => .{ .number = a / b },
            .greater => .{ .bool = a > b },
            .less => .{ .bool = a < b },
            else => unreachable,
        });
    }

    pub fn interpret(self: *VM, allocator: Allocator, source: []const u8) Error!void {
        const function = try compiler.compile(allocator, &self.gc, source);

        self.push(Value{ .obj = &function.obj });
        const frame = &self.frames[self.frame_count];
        self.frame_count += 1;
        frame.function = function;
        frame.ip = 0;
        frame.slots = self.stack.items.ptr;

        try self.run(allocator);

        // TODO: pop <script>
        _ = self.pop();
    }
};
