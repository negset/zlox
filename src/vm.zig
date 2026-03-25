const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const compiler = @import("compiler.zig");
const GC = @import("memory.zig").GC;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");

const stack_max: usize = 256;

pub const RuntimeError = error{InvalidOperand} || Allocator.Error;
pub const Error = RuntimeError || compiler.Error;

pub const VM = struct {
    chunk: *const Chunk,
    ip: usize,
    stack: std.ArrayList(Value),
    gc: GC,

    pub fn init(allocator: Allocator) Allocator.Error!VM {
        return .{
            .chunk = undefined,
            .ip = undefined,
            .stack = try .initCapacity(allocator, stack_max),
            .gc = .init,
        };
    }

    pub fn deinit(self: *VM, allocator: Allocator) void {
        self.stack.deinit(allocator);
        self.gc.deinit(allocator);
    }

    fn runtimeError(self: *VM, err: RuntimeError, comptime fmt: []const u8, args: anytype) RuntimeError {
        const line = self.chunk.code.items[self.ip - 1].line;
        std.debug.print("[line {d}] {s} (runtime): ", .{ line, @errorName(err) });
        std.debug.print(fmt ++ "\n", args);

        self.stack.shrinkRetainingCapacity(0);
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

    fn run(self: *VM, allocator: Allocator, chunk: *const Chunk) RuntimeError!void {
        self.chunk = chunk;
        self.ip = 0;

        while (true) {
            if (comptime debug.trace_execution) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ ", .{});
                    slot.print();
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});
                _ = debug.disassembleInstruction(self.chunk, self.ip);
            }

            const instruction: OpCode = @enumFromInt(self.readByte());
            switch (instruction) {
                .constant => self.push(self.readConstant()),
                .nil => self.push(.{ .nil = {} }),
                .true => self.push(.{ .bool = true }),
                .false => self.push(.{ .bool = false }),
                .pop => _ = self.pop(),
                .get_global => {
                    const name = self.readString();
                    if (self.gc.globals.get(name)) |value| {
                        self.push(value);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Undefined variable '{s}'.",
                        .{name.string},
                    );
                },
                .define_global => {
                    const name = self.readString();
                    // To avoid GC, pop value after put it to the table.
                    try self.gc.globals.put(allocator, name, self.peek(0));
                    _ = self.pop();
                },
                .set_global => {
                    const name = self.readString();
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
                .@"return" => {
                    // Exit interpreter.
                    return;
                },
            }
        }
    }

    fn readByte(self: *VM) u8 {
        defer self.ip += 1;
        return self.chunk.code.items[self.ip].byte;
    }

    fn readConstant(self: *VM) Value {
        return self.chunk.constants.items[readByte(self)];
    }

    fn readString(self: *VM) *const ObjString {
        return self.readConstant().obj.as(ObjString);
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
        var chunk = Chunk.empty;
        defer chunk.deinit(allocator);

        try compiler.compile(allocator, &self.gc, source, &chunk);
        try self.run(allocator, &chunk);
    }
};
