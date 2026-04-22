const std = @import("std");
const Allocator = std.mem.Allocator;
const OpCode = @import("chunk.zig").OpCode;
const Compiler = @import("compiler.zig").Compiler;
const Parser = @import("parser.zig").Parser;
const GC = @import("memory.zig").GC;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjNative = @import("object.zig").ObjNative;
const ObjString = @import("object.zig").ObjString;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const config = @import("config");

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
        const buf = self.function.chunk.code.items[self.ip..][0..2];
        return std.mem.readInt(u16, buf, .big);
    }

    pub fn readConstant(self: *CallFrame) Value {
        return self.function.chunk.constants.items[self.readByte()];
    }

    pub fn readString(self: *CallFrame) *const ObjString {
        return self.readConstant().obj.as(.string);
    }
};

pub const VM = struct {
    frames: [frames_max]CallFrame,
    frame_count: usize,
    stack: std.ArrayList(Value),
    gc: GC,
    io: std.Io,

    const RuntimeError = error{ InvalidOperand, StackOverflow } || Allocator.Error;
    const Error = RuntimeError || Parser.Error;

    const frames_max = 64;
    const stack_max = frames_max * Compiler.locals_max;

    pub fn init(gpa: Allocator, io: std.Io) Allocator.Error!VM {
        var new = VM{
            .frames = undefined,
            .frame_count = 0,
            .stack = try .initCapacity(gpa, stack_max),
            .gc = .init,
            .io = io,
        };
        try new.defineNative(gpa, "clock", clockNative);
        return new;
    }

    pub fn deinit(self: *VM, gpa: Allocator) void {
        self.stack.deinit(gpa);
        self.gc.deinit(gpa);
    }

    fn clockNative(self: *VM, _: u8, _: [*]Value) Value {
        return Value{ .number = @floatFromInt(std.Io.Clock.real.now(self.io).toSeconds()) };
    }

    fn resetStack(self: *VM) void {
        self.stack.shrinkRetainingCapacity(0);
        self.frame_count = 0;
    }

    fn runtimeError(self: *VM, err: RuntimeError, comptime fmt: []const u8, args: anytype) RuntimeError {
        std.debug.print("{s} (runtime): ", .{@errorName(err)});
        std.debug.print(fmt ++ "\n", args);

        for (0..self.frame_count) |i| {
            const frame = &self.frames[self.frame_count - i - 1];
            const function = frame.function;
            const instruction = frame.ip - 1;
            std.debug.print("[line {d}] in ", .{function.chunk.lines.items[instruction]});
            if (function.name) |name| {
                std.debug.print("{s}()\n", .{name.string});
            } else {
                std.debug.print("script\n", .{});
            }
        }

        self.resetStack();
        return err;
    }

    fn defineNative(self: *VM, gpa: Allocator, name: []const u8, native_fn: ObjNative.NativeFn) Allocator.Error!void {
        const obj_string = try ObjString.createByCopy(gpa, &self.gc, name);
        const obj_native = try ObjNative.create(gpa, &self.gc, native_fn);
        // To prevent GC from collecting name and function, store them on the stack.
        self.push(Value{ .obj = &obj_string.obj });
        self.push(Value{ .obj = &obj_native.obj });
        try self.gc.globals.put(
            gpa,
            self.stack.items[0].obj.as(.string),
            self.stack.items[1],
        );
        _ = self.pop();
        _ = self.pop();
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

    fn call(self: *VM, function: *const ObjFunction, arg_count: u8) RuntimeError!void {
        if (arg_count != function.arity) {
            return self.runtimeError(
                error.InvalidOperand,
                "Expected {d} arguments but got {d}.",
                .{ function.arity, arg_count },
            );
        }

        if (self.frame_count == frames_max) {
            return self.runtimeError(
                error.StackOverflow,
                "Stack overflow.",
                .{},
            );
        }

        const frame = &self.frames[self.frame_count];
        frame.function = function;
        frame.ip = 0;
        // The frame starts at stack_top - (arg_count + 1),
        // pointing to the function followed by its arguments.
        frame.slots = (self.stack.items.ptr + self.stack.items.len) - (arg_count + 1);
        self.frame_count += 1;
    }

    fn callValue(self: *VM, callee: Value, arg_count: u8) RuntimeError!void {
        if (callee == .obj) {
            switch (callee.obj.obj_type) {
                .function => {
                    try self.call(callee.obj.as(.function), arg_count);
                    return;
                },
                .native => {
                    const native = callee.obj.as(.native);
                    const args = self.stack.items.ptr + self.stack.items.len - arg_count;
                    const result = native.native_fn(self, arg_count, args);
                    // Discard args and native function name.
                    const len = self.stack.items.len - (arg_count + 1);
                    self.stack.shrinkRetainingCapacity(len);
                    self.push(result);
                    return;
                },
                else => {}, // Non-callable object type.
            }
        }
        return self.runtimeError(
            error.InvalidOperand,
            "Can only call functions and classes.",
            .{},
        );
    }

    fn concatenate(self: *VM, gpa: Allocator) Allocator.Error!void {
        const b = self.pop().obj.as(.string).string;
        const a = self.pop().obj.as(.string).string;
        const string = try std.mem.concat(gpa, u8, &.{ a, b });

        const result = try ObjString.createByTake(gpa, &self.gc, string);
        self.push(Value{ .obj = &result.obj });
    }

    fn run(self: *VM, gpa: Allocator) RuntimeError!void {
        var frame = &self.frames[self.frame_count - 1];

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

            switch (@as(OpCode, @enumFromInt(frame.readByte()))) {
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
                    // To prevent GC from collecting the value when calling "globals.put",
                    // use "peek" instead of "pop".
                    try self.gc.globals.put(gpa, name, self.peek(0));
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
                inline .greater,
                .less,
                .subtract,
                .multiply,
                .divide,
                => |instruction| try self.binaryOp(instruction),
                .add => {
                    if (self.peek(0).isObjType(.string) and self.peek(1).isObjType(.string)) {
                        try self.concatenate(gpa);
                    } else if (self.peek(0) == .number and self.peek(1) == .number) {
                        try self.binaryOp(.add);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Operands must be two numbers or two strings.",
                        .{},
                    );
                },
                .not => self.push(.{ .bool = self.pop().isFalsey() }),
                .negate => switch (self.peek(0)) {
                    .number => self.push(.{ .number = -(self.pop().number) }),
                    else => return self.runtimeError(
                        error.InvalidOperand,
                        "Operand must be a number.",
                        .{},
                    ),
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
                .call => {
                    const arg_count = frame.readByte();
                    try self.callValue(self.peek(arg_count), arg_count);
                    frame = &self.frames[self.frame_count - 1];
                },
                .@"return" => {
                    const result = self.pop();
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        // Exit interpreter.
                        _ = self.pop();
                        return;
                    }

                    // Discard call frame.
                    const len = frame.slots - self.stack.items.ptr;
                    self.stack.shrinkRetainingCapacity(len);
                    self.push(result);
                    frame = &self.frames[self.frame_count - 1];
                },
            }
        }
    }

    fn binaryOp(self: *VM, comptime instruction: OpCode) RuntimeError!void {
        if (self.peek(0) != .number or self.peek(1) != .number) {
            return self.runtimeError(
                error.InvalidOperand,
                "Operands must be numbers.",
                .{},
            );
        }
        const b = self.pop().number;
        const a = self.pop().number;

        self.push(switch (comptime instruction) {
            .add => .{ .number = a + b },
            .subtract => .{ .number = a - b },
            .multiply => .{ .number = a * b },
            .divide => .{ .number = a / b },
            .greater => .{ .bool = a > b },
            .less => .{ .bool = a < b },
            else => unreachable,
        });
    }

    pub fn interpret(self: *VM, gpa: Allocator, source: []const u8) Error!void {
        var parser = Parser.init(source, &self.gc);
        const script = try parser.run(gpa);

        self.push(Value{ .obj = &script.obj });
        try self.call(script, 0);

        try self.run(gpa);
    }
};
