const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    constant,
    nil,
    true,
    false,
    pop,
    get_local,
    set_local,
    get_global,
    define_global,
    set_global,
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
    jump,
    jump_if_false,
    loop,
    @"return",
};

pub const Chunk = struct {
    code: std.ArrayList(u8),
    lines: std.ArrayList(u32),
    constants: std.ArrayList(Value),

    pub const empty = Chunk{
        .code = .empty,
        .lines = .empty,
        .constants = .empty,
    };

    pub fn deinit(self: *Chunk, allocator: Allocator) void {
        self.code.deinit(allocator);
        self.lines.deinit(allocator);
        self.constants.deinit(allocator);
    }

    pub fn write(self: *Chunk, allocator: Allocator, byte: u8, line: u32) Allocator.Error!void {
        try self.code.append(allocator, byte);
        try self.lines.append(allocator, line);
    }

    pub fn addConstant(self: *Chunk, allocator: Allocator, value: Value) Allocator.Error!usize {
        try self.constants.append(allocator, value);
        return self.constants.items.len - 1;
    }
};
