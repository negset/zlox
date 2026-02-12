const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const compiler = @import("compiler.zig");
const value = @import("value.zig");
const Value = value.Value;
const debug = @import("debug.zig");

const stack_max: usize = 256;

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const VM = struct {
    chunk: *Chunk,
    ip: [*]const u8,
    stack: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator) !VM {
        return .{
            .chunk = undefined,
            .ip = undefined,
            .stack = try .initCapacity(allocator, stack_max),
        };
    }

    pub fn deinit(self: *VM, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
    }

    fn push(self: *VM, v: Value) void {
        self.stack.appendBounded(v) catch @panic("Stack overflow.");
    }

    fn pop(self: *VM) Value {
        return self.stack.pop() orelse @panic("Stack underflow.");
    }

    fn run(self: *VM) InterpretResult {
        while (true) {
            if (debug.trace_execution) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ {} ]", .{slot});
                }
                std.debug.print("\n", .{});
                _ = debug.disassembleInstruction(self.chunk, self.ip - self.chunk.code.items.ptr);
            }

            const instruction: OpCode = @enumFromInt(readByte(self));
            switch (instruction) {
                .constant => self.push(readConstant(self)),
                .add => self.binaryOp(.add),
                .subtract => self.binaryOp(.subtract),
                .multiply => self.binaryOp(.multiply),
                .divide => self.binaryOp(.divide),
                .negate => self.push(-self.pop()),
                .@"return" => {
                    value.print(self.pop());
                    std.debug.print("\n", .{});
                    return .ok;
                },
            }
        }
    }

    fn readByte(self: *VM) u8 {
        const byte = self.ip[0];
        self.ip += 1;
        return byte;
    }

    fn readConstant(self: *VM) Value {
        return self.chunk.constants.values.items[readByte(self)];
    }

    fn binaryOp(self: *VM, comptime op: OpCode) void {
        const b = self.pop();
        const a = self.pop();
        self.push(switch (op) {
            .add => a + b,
            .subtract => a - b,
            .multiply => a * b,
            .divide => a / b,
            else => unreachable,
        });
    }

    pub fn interpret(self: *VM, source: []const u8) InterpretResult {
        _ = self;
        compiler.compile(source);
        return .ok;
    }
};
