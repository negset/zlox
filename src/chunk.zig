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
    call,
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

    pub fn deinit(self: *Chunk, gpa: Allocator) void {
        self.code.deinit(gpa);
        self.lines.deinit(gpa);
        self.constants.deinit(gpa);
    }

    pub fn write(self: *Chunk, gpa: Allocator, byte: u8, line: u32) Allocator.Error!void {
        try self.code.append(gpa, byte);
        try self.lines.append(gpa, line);
    }

    pub fn addConstant(self: *Chunk, gpa: Allocator, value: Value) Allocator.Error!usize {
        try self.constants.append(gpa, value);
        return self.constants.items.len - 1;
    }
};
