const std = @import("std");
const allocator = std.heap.wasm_allocator;

extern fn js_out(ptr: [*]const u8, len: usize) void;

export fn alloc(len: usize) ?[*]const u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn runSource(ptr: [*]const u8, len: usize) void {
    js_out(ptr, len);
}
