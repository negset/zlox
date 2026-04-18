const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var vm = try VM.init(init.gpa, init.io);
    defer vm.deinit(init.gpa);

    switch (args.len) {
        1 => repl(init.gpa, init.io, &vm),
        2 => runFile(init.gpa, init.io, &vm, args[1]),
        else => {
            std.debug.print("Usage: zlox [path]\n", .{});
            std.process.exit(64);
        },
    }
}

fn repl(gpa: Allocator, io: std.Io, vm: *VM) void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;
    while (true) {
        std.debug.print("> ", .{});

        const line = stdin.takeDelimiterInclusive('\n') catch {
            std.debug.print("\n", .{});
            break;
        };

        // Ignore error.
        vm.interpret(gpa, line) catch {};
    }
}

fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const file_size = try file.length(io);

    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);

    const contents = try file_reader.interface.readAlloc(gpa, file_size);
    return contents;
}

fn runFile(gpa: Allocator, io: std.Io, vm: *VM, path: []const u8) void {
    const source = readFile(gpa, io, path) catch |err| {
        std.debug.print("Could not read file \"{s}\": {}", .{ path, err });
        std.process.exit(74);
    };
    defer gpa.free(source);

    vm.interpret(gpa, source) catch |err| switch (err) {
        error.InvalidSyntax,
        error.TooManyElements,
        error.InvalidOperand,
        error.Overflow,
        => std.process.exit(65),
        error.OutOfMemory => std.process.exit(71),
    };
}
