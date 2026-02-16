const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const VM = @import("vm.zig").VM;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory leak.");
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var vm = try VM.init(allocator);
    defer vm.deinit(allocator);

    switch (args.len) {
        1 => repl(&vm, allocator),
        2 => runFile(&vm, allocator, args[1]),
        else => {
            std.debug.print("Usage: zlox [path]\n", .{});
            std.process.exit(64);
        },
    }
}

fn repl(vm: *VM, allocator: std.mem.Allocator) void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;
    while (true) {
        std.debug.print("> ", .{});

        const line = stdin.takeDelimiterInclusive('\n') catch {
            std.debug.print("\n", .{});
            break;
        };

        _ = vm.interpret(allocator, line);
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();

    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&file_buffer);

    const contents = try file_reader.interface.readAlloc(allocator, file_size);
    return contents;
}

fn runFile(vm: *VM, allocator: std.mem.Allocator, path: []const u8) void {
    const source = readFile(allocator, path) catch |err| {
        std.debug.print("Could not read file \"{s}\": {}", .{ path, err });
        std.process.exit(74);
    };
    defer allocator.free(source);
    const result = vm.interpret(allocator, source);

    switch (result) {
        .compile_error => std.posix.exit(65),
        .runtime_error => std.posix.exit(70),
        .ok => return,
    }
}
