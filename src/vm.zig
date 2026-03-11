const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const compiler = @import("compiler.zig");
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");

const stack_max: usize = 256;

pub const RuntimeError = error{InvalidOperand};
pub const Error = RuntimeError || compiler.Error;

pub const VM = struct {
    chunk: *Chunk,
    ip: [*]const u8,
    stack: std.ArrayList(Value),

    pub fn init(allocator: Allocator) Allocator.Error!VM {
        return .{
            .chunk = undefined,
            .ip = undefined,
            .stack = try .initCapacity(allocator, stack_max),
        };
    }

    pub fn deinit(self: *VM, allocator: Allocator) void {
        self.stack.deinit(allocator);
    }

    fn runtimeError(self: *VM, err: RuntimeError, comptime fmt: []const u8, args: anytype) RuntimeError {
        const offset = self.ip - self.chunk.code.items.ptr - 1;
        const line = self.chunk.lines.items[offset];
        std.debug.print("[line {d}] (runtime) {s}: ", .{ line, @errorName(err) });
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

    fn isFalsey(value: Value) bool {
        return value == .nil or (value == .bool and !value.bool);
    }

    fn run(self: *VM) RuntimeError!void {
        while (true) {
            if (comptime debug.trace_execution) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ ", .{});
                    slot.print();
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});
                _ = debug.disassembleInstruction(self.chunk, self.ip - self.chunk.code.items.ptr);
            }

            const instruction: OpCode = @enumFromInt(readByte(self));
            switch (instruction) {
                .constant => self.push(readConstant(self)),
                .nil => self.push(.{ .nil = {} }),
                .true => self.push(.{ .bool = true }),
                .false => self.push(.{ .bool = false }),
                .equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(.{ .bool = a.equals(b) });
                },
                .greater => try self.binaryOp(.greater),
                .less => try self.binaryOp(.less),
                .add => try self.binaryOp(.add),
                .subtract => try self.binaryOp(.subtract),
                .multiply => try self.binaryOp(.multiply),
                .divide => try self.binaryOp(.divide),
                .not => self.push(.{ .bool = isFalsey(self.pop()) }),
                .negate => switch (self.peek(0)) {
                    .number => self.push(.{ .number = -(self.pop().number) }),
                    else => return self.runtimeError(error.InvalidOperand, "Operand must be a number.", .{}),
                },
                .@"return" => {
                    self.pop().print();
                    std.debug.print("\n", .{});
                    return;
                },
            }
        }
    }

    fn readByte(self: *VM) u8 {
        defer self.ip += 1;
        return self.ip[0];
    }

    fn readConstant(self: *VM) Value {
        return self.chunk.constants.values.items[readByte(self)];
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
        var chunk = Chunk.init();
        defer chunk.deinit(allocator);

        try compiler.compile(allocator, source, &chunk);

        self.chunk = &chunk;
        self.ip = self.chunk.code.items.ptr;

        try self.run();
    }
};
