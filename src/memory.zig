const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const Table = std.HashMapUnmanaged(
    *const ObjString,
    Value,
    ObjString.Context,
    75,
);
const ObjType = @import("object.zig").ObjType;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;
const Value = @import("value.zig").Value;
const config = @import("config");

pub const GC = struct {
    backing: Allocator,
    strings: Table,
    objects: ?*Obj,

    pub fn init(backing: Allocator) @This() {
        return .{
            .backing = backing,
            .strings = .empty,
            .objects = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.freeObjects();
        self.strings.deinit(self.allocator());
    }

    pub fn allocator(self: *@This()) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn createObject(self: *@This(), comptime obj_type: ObjType) Allocator.Error!*obj_type.Impl() {
        const new = try self.allocator().create(obj_type.Impl());
        new.obj.obj_type = obj_type;
        new.obj.next = self.objects;
        self.objects = &new.obj;

        if (comptime config.log_gc) {
            std.debug.print("{*} allocate {} for {}\n", .{ new, @sizeOf(obj_type.Impl()), obj_type });
        }

        return new;
    }

    pub fn freeObjects(self: *@This()) void {
        var curr = self.objects;
        while (curr) |obj| {
            if (comptime config.log_gc) {
                std.debug.print("{*} free type {}\n", .{ obj, obj.obj_type });
            }

            const next = obj.next;
            obj.destroy(self.allocator());
            curr = next;
        }
        self.objects = null;
    }

    pub fn findString(self: *@This(), string: []const u8, hash: u64) ?*const ObjString {
        return self.strings.getKey(&.{
            .obj = undefined,
            .string = string,
            .hash = hash,
        });
    }

    fn markRoots() void {}

    fn collectGarbage() void {
        if (comptime config.log_gc) {
            std.debug.print("-- gc begin\n", .{});
        }

        markRoots();

        if (comptime config.log_gc) {
            std.debug.print("-- gc end\n", .{});
        }
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        std.debug.print("[alloc] len: {}\n", .{len});

        if (comptime config.stress_gc) {
            collectGarbage();
        }

        const self: *@This() = @ptrCast(@alignCast(ctx));

        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;

        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        std.debug.print("[resize] len: {} -> {}, ptr: {*}\n", .{ memory.len, new_len, memory.ptr });

        if (new_len > memory.len) {
            collectGarbage();
        }

        const self: *@This() = @ptrCast(@alignCast(ctx));

        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        std.debug.print("[remap] len: {} -> {}, ptr: {*}\n", .{ memory.len, new_len, memory.ptr });

        if (new_len > memory.len) {
            collectGarbage();
        }

        const self: *@This() = @ptrCast(@alignCast(ctx));

        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        std.debug.print("[free] len: {}, ptr: {*}\n", .{ memory.len, memory.ptr });

        const self: *@This() = @ptrCast(@alignCast(ctx));

        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
