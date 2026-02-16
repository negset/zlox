const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const value = @import("value.zig");

pub const trace_execution = true;

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
    switch (instruction) {
        .constant => {
            return constantInstruction("constant", chunk, offset);
        },
        .add => {
            return simpleInstruction("add", offset);
        },
        .subtract => {
            return simpleInstruction("subtract", offset);
        },
        .multiply => {
            return simpleInstruction("multiply", offset);
        },
        .divide => {
            return simpleInstruction("divide", offset);
        },
        .negate => {
            return simpleInstruction("negate", offset);
        },
        .@"return" => {
            return simpleInstruction("return", offset);
        },
        // else => {
        //     std.debug.print("Unknown opcode {d}\n", .{instruction});
        //     return offset + 1;
        // },
    }
}

fn constantInstruction(name: []const u8, chunk: *const Chunk, offset: usize) usize {
    const constant = chunk.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4} '", .{ name, constant });
    value.print(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}
