const std = @import("std");
const Writer = std.Io.Writer;
const Natives = @import("vm.zig").Natives;
const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

const allocator = std.heap.wasm_allocator;

const WasmWriter = struct {
    interface: Writer,
    is_err: bool,

    pub fn init(buffer: []u8, is_err: bool) @This() {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
            .is_err = is_err,
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        if (data.len == 0) return 0;

        const self: *@This() = @fieldParentPtr("interface", w);

        if (w.end > 0) {
            const buffered = w.buffered();
            js_write(buffered.ptr, buffered.len, self.is_err);
            w.end = 0;
        }

        var total_consumed: usize = 0;

        for (data[0 .. data.len - 1]) |slice| {
            js_write(slice.ptr, slice.len, self.is_err);
            total_consumed += slice.len;
        }

        const last = data[data.len - 1];
        for (0..splat) |_| {
            js_write(last.ptr, last.len, self.is_err);
        }
        total_consumed += last.len * splat;

        return total_consumed;
    }
};

const WasmNatives = struct {
    pub fn natives(self: *@This()) Natives {
        return .{
            .ptr = self,
            .vtable = &.{
                .clock = clock,
            },
        };
    }

    fn clock(_: *VM, _: u8, _: [*]Value) Value {
        return .init(js_clock());
    }
};

extern fn js_clock() f64;
extern fn js_write(ptr: [*]const u8, len: usize, is_err: bool) void;

export fn alloc(len: usize) ?[*]const u8 {
    const mem = allocator.alloc(u8, len) catch return null;
    return mem.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn runSource(ptr: [*]const u8, len: usize) i64 {
    var out_buf: [1024]u8 = undefined;
    var out_writer = WasmWriter.init(&out_buf, false);
    const out = &out_writer.interface;

    var err_buf: [1024]u8 = undefined;
    var err_writer = WasmWriter.init(&err_buf, true);
    const err = &err_writer.interface;

    var natives = WasmNatives{};

    var vm: VM = undefined;
    vm.init(allocator, out, err, natives.natives()) catch {
        err.print("Can't initialize VM.\n", .{}) catch {};
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
