const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;

pub fn disassembleChunk(chunk: *const Chunk, name: []const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = disassembleInstruction(chunk, offset);
    }
}

pub fn disassembleInstruction(chunk: *const Chunk, offset: usize) usize {
    std.debug.print("{d:0>4} ", .{offset});
    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:>4} ", .{chunk.lines.items[offset]});
    }

    const instruction: OpCode = @enumFromInt(chunk.code.items[offset]);
    return switch (instruction) {
        .constant,
        .get_global,
        .define_global,
        .set_global,
        => constantInstruction(@tagName(instruction), chunk, offset),
        .get_local,
        .set_local,
        => byteInstruction(@tagName(instruction), chunk, offset),
        .jump,
        .jump_if_false,
        => jumpInstruction(@tagName(instruction), true, chunk, offset),
        .loop,
        => jumpInstruction(@tagName(instruction), false, chunk, offset),
        else => simpleInstruction(@tagName(instruction), offset),
    };
}

fn constantInstruction(name: []const u8, chunk: *const Chunk, offset: usize) usize {
    const constant = chunk.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4} '", .{ name, constant });
    chunk.constants.items[constant].print();
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}

fn byteInstruction(name: []const u8, chunk: *const Chunk, offset: usize) usize {
    const slot = chunk.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4}\n", .{ name, slot });
    return offset + 2;
}

fn jumpInstruction(name: []const u8, comptime is_forward: bool, chunk: *const Chunk, offset: usize) usize {
    const buf = chunk.code.items[offset + 1 ..];
    const distance = std.mem.readInt(u16, buf[0..2], .big);
    const dest = if (is_forward) offset + 3 + distance else offset + 3 - distance;
    std.debug.print("{s:<16} {d:>4} -> {d}\n", .{ name, offset, dest });
    return offset + 3;
}
