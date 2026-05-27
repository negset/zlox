const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Obj = @import("object.zig").Obj;

pub fn disassembleChunk(chunk: *const Chunk, name: []const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = disassembleInstruction(chunk, offset);
    }
}

fn constantInstruction(name: []const u8, chunk: *const Chunk, offset: usize) usize {
    const constant = chunk.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4} '", .{ name, constant });
    chunk.constants.items[constant].print();
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn invokeInstruction(name: []const u8, chunk: *const Chunk, offset: usize) usize {
    const constant = chunk.code.items[offset + 1];
    const arg_count = chunk.code.items[offset + 2];
    std.debug.print("{s:<16} ({} args) {d:>4} '", .{ name, arg_count, constant });
    chunk.constants.items[constant].print();
    std.debug.print("'\n", .{});
    return offset + 3;
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
    const buf = chunk.code.items[offset + 1 ..][0..2];
    const distance = std.mem.readInt(u16, buf, .big);
    const dest = if (is_forward) offset + 3 + distance else offset + 3 - distance;
    std.debug.print("{s:<16} {d:>4} -> {d}\n", .{ name, offset, dest });
    return offset + 3;
}

pub fn disassembleInstruction(chunk: *const Chunk, offset: usize) usize {
    std.debug.print("{d:0>4} ", .{offset});
    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:>4} ", .{chunk.lines.items[offset]});
    }

    const instruction: OpCode = @enumFromInt(chunk.code.items[offset]);
    const name = @tagName(instruction);

    return switch (instruction) {
        .constant,
        .get_global,
        .define_global,
        .set_global,
        .get_property,
        .set_property,
        .get_super,
        .class,
        .method,
        => constantInstruction(name, chunk, offset),

        .invoke,
        .super_invoke,
        => invokeInstruction(name, chunk, offset),

        .get_local,
        .set_local,
        .get_upvalue,
        .set_upvalue,
        .call,
        => byteInstruction(name, chunk, offset),

        .jump,
        .jump_if_false,
        => jumpInstruction(name, true, chunk, offset),

        .loop,
        => jumpInstruction(name, false, chunk, offset),

        .closure,
        => blk: {
            const constant = chunk.code.items[offset + 1];
            std.debug.print("{s:<16} {d:>4} ", .{ name, constant });
            const value = chunk.constants.items[constant];
            value.print();
            std.debug.print("\n", .{});

            const function = value.as(*Obj).as(.function);

            const upvalue_base = offset + 2;
            for (0..function.upvalue_count) |i| {
                const upvalue_offset = upvalue_base + i * 2;
                const is_local = chunk.code.items[upvalue_offset];
                const index = chunk.code.items[upvalue_offset + 1];

                std.debug.print("{d:0>4}      |                     {s} {d}\n", .{
                    upvalue_offset,
                    if (is_local != 0) "local" else "upvalue",
                    index,
                });
            }

            break :blk upvalue_base + function.upvalue_count * 2;
        },

        else => simpleInstruction(name, offset),
    };
}
