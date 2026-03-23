const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    constant,
    nil,
    true,
    false,
    pop,
    equal,
    greater,
    less,
    add,
    subtract,
    multiply,
    divide,
    not,
    negate,
    print,
    @"return",
};

pub const Chunk = struct {
    code: std.ArrayList(struct { byte: u8, line: u32 }),
    constants: std.ArrayList(Value),

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .constants = .empty,
        };
    }

    pub fn deinit(self: *Chunk, allocator: Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
    }

    pub fn write(self: *Chunk, allocator: Allocator, byte: u8, line: u32) Allocator.Error!void {
        try self.code.append(allocator, .{
            .byte = byte,
            .line = line,
        });
    }

    pub fn addConstant(self: *Chunk, allocator: Allocator, value: Value) Allocator.Error!usize {
        try self.constants.append(allocator, value);
        return self.constants.items.len - 1;
    }
};
