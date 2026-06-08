const std = @import("std");
const Allocator = std.mem.Allocator;
const GC = @import("memory.zig").GC;
const VM = @import("vm.zig").VM;

const NativeFn = @import("object.zig").ObjNative.NativeFn;
const Value = @import("value.zig").Value;

fn repl(io: std.Io, vm: *VM) void {
    var buf: [1024]u8 = undefined;
    var freader = std.Io.File.stdin().reader(io, &buf);
    const reader = &freader.interface;

    while (true) {
        std.debug.print("> ", .{});

        const line = reader.takeDelimiterInclusive('\n') catch {
            std.debug.print("\n", .{});
            break;
        };

        // Ignore error.
        vm.interpret(line) catch {};
    }
}

fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const len = try file.length(io);

    var buf: [4096]u8 = undefined;
    var freader = file.reader(io, &buf);
    const reader = &freader.interface;

    return try reader.readAlloc(gpa, len);
}

fn runFile(gpa: Allocator, io: std.Io, vm: *VM, path: []const u8) void {
    const source = readFile(gpa, io, path) catch |err| {
        std.debug.print("Could not read file \"{s}\": {}", .{ path, err });
        std.process.exit(74);
    };
    defer gpa.free(source);

    vm.interpret(source) catch |err| switch (err) {
        error.InvalidSyntax,
        error.TooManyElements,
        error.InvalidOperand,
        error.StackOverflow,
        => std.process.exit(65),
        error.OutOfMemory,
        error.WriteFailed,
        => std.process.exit(71),
    };
}

fn clockNative(_: *VM, _: u8, _: [*]Value) Value {
    const clock = std.Io.Clock.real;
    const timestamp: f64 = @floatFromInt(clock.now(io).toSeconds());
    return .init(timestamp);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [1024]u8 = undefined;
    var out_fwriter = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &out_fwriter.interface;

    var err_buf: [1024]u8 = undefined;
    var err_fwriter = std.Io.File.stderr().writer(init.io, &err_buf);
    const err = &err_fwriter.interface;

    var vm: VM = undefined;
    try vm.init(init.gpa, out, err, init.io);
    defer vm.deinit();

    vm.defineNative("clock", nativeFunctions(init.io));

    switch (args.len) {
        1 => repl(init.io, &vm),
        2 => runFile(init.gpa, init.io, &vm, args[1]),
        else => {
            std.debug.print("Usage: zlox [path]\n", .{});
            std.process.exit(64);
        },
    }
}

test {
    // Refer other tests in the root file.
    _ = @import("chunk.zig");
    _ = @import("compiler.zig");
    _ = @import("debug.zig");
    _ = @import("memory.zig");
    _ = @import("object.zig");
    _ = @import("parser.zig");
    _ = @import("scanner.zig");
    _ = @import("value.zig");
    _ = @import("vm.zig");
}
