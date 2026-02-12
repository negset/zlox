const std = @import("std");
const Value = @import("value.zig").Value;
const ValueArray = @import("value.zig").ValueArray;

pub const OpCode = enum(u8) {
    constant,
    add,
    subtract,
    multiply,
    divide,
    negate,
    @"return",
};

pub const Chunk = struct {
    code: std.ArrayList(u8),
    lines: std.ArrayList(u32),
    constants: ValueArray,

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .lines = .empty,
            .constants = .init(),
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.lines.deinit(allocator);
        self.constants.deinit(allocator);
    }

    pub fn write(self: *Chunk, allocator: std.mem.Allocator, byte: u8, line: u32) !void {
        try self.code.append(allocator, byte);
        try self.lines.append(allocator, line);
    }

    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, value: Value) !usize {
        try self.constants.write(allocator, value);
        return self.constants.values.items.len - 1;
    }
};
