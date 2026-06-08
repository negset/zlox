const std = @import("std");
const Writer = std.Io.Writer;
const Natives = @import("vm.zig").Natives;
const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

const allocator = std.heap.wasm_allocator;

const WasmWriter = struct {
    interface: Writer,

    pub fn init(_: []u8) @This() {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
        };
    }

    fn drain(w: *Writer, data: []const []const u8, _: usize) Writer.Error!usize {
        if (data.len == 0) return 0;

        if (w.end > 0) {
            const buffered = w.buffered();
            js_out(buffered.ptr, buffered.len);
            w.end = 0;
        }

        const bytes_to_write = data[0];
        js_out(bytes_to_write.ptr, bytes_to_write.len);
        return bytes_to_write.len;
    }
};

const WasmNatives = struct {
    pub fn natives(self: *@This()) Natives {
        return .{
            .ptr = self,
            .vtable = &.{
                .now = now,
            },
        };
    }

    fn now(_: *VM, _: u8, _: [*]Value) Value {
        return .init(js_now());
    }
};

extern fn js_now() f64;
extern fn js_out(ptr: [*]const u8, len: usize) void;

export fn alloc(len: usize) ?[*]const u8 {
    const mem = allocator.alloc(u8, len) catch return null;
    return mem.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn runSource(ptr: [*]const u8, len: usize) i64 {
    var out_buf: [1024]u8 = undefined;
    var out_writer = WasmWriter.init(&out_buf);
    const out = &out_writer.interface;

    var err_buf: [1024]u8 = undefined;
    var err_writer = WasmWriter.init(&err_buf);
    const err = &err_writer.interface;

    var natives = WasmNatives{};

    var vm: VM = undefined;
    vm.init(allocator, out, err, natives.natives()) catch {
        err.print("Can't init VM.\n", .{}) catch {};
        return 70;
    };
    defer vm.deinit();

    vm.interpret(ptr[0..len]) catch |e| switch (e) {
        error.InvalidSyntax,
        error.TooManyElements,
        error.InvalidOperand,
        error.StackOverflow,
        => return 65,
        error.OutOfMemory,
        error.WriteFailed,
        => return 71,
    };

    return 0;
}
