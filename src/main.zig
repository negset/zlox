const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

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
        1 => repl(allocator, &vm),
        2 => runFile(allocator, &vm, args[1]),
        else => {
            std.debug.print("Usage: zlox [path]\n", .{});
            std.process.exit(64);
        },
    }
}

fn repl(allocator: Allocator, vm: *VM) void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;
    while (true) {
        std.debug.print("> ", .{});

        const line = stdin.takeDelimiterInclusive('\n') catch {
            std.debug.print("\n", .{});
            break;
        };

        // Ignore error.
        vm.interpret(allocator, line) catch {};
    }
}

fn readFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();

    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&file_buffer);

    const contents = try file_reader.interface.readAlloc(allocator, file_size);
    return contents;
}

fn runFile(allocator: Allocator, vm: *VM, path: []const u8) void {
    const source = readFile(allocator, path) catch |err| {
        std.debug.print("Could not read file \"{s}\": {}", .{ path, err });
        std.process.exit(74);
    };
    defer allocator.free(source);

    vm.interpret(allocator, source) catch |err| switch (err) {
        error.InvalidSyntax,
        error.TooManyElements,
        => std.process.exit(65),
        error.InvalidOperand => std.process.exit(70),
        error.OutOfMemory => std.process.exit(71),
    };
}
