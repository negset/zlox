const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const Table = std.HashMapUnmanaged(
    *ObjString,
    Value,
    ObjString.Context,
    75,
);
const ObjType = @import("object.zig").ObjType;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;
const Value = @import("value.zig").Value;
const config = @import("config");

pub const Roots = struct {
    stack: *std.ArrayList(Value),
    globals: *Table,
};

pub const GC = struct {
    backing: Allocator,
    strings: Table,
    objects: ?*Obj,
    roots: Roots,

    pub fn init(backing: Allocator, roots: Roots) @This() {
        return .{
            .backing = backing,
            .strings = .empty,
            .objects = null,
            .roots = roots,
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
        new.obj.is_marked = false;
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

    pub fn findString(self: *@This(), string: []const u8, hash: u64) ?*ObjString {
        var key = ObjString{
            .obj = undefined,
            .string = string,
            .hash = hash,
        };
        return self.strings.getKey(&key);
    }

    fn markObject(object: ?*Obj) void {
        if (object) |obj| {
            if (comptime config.log_gc) {
                std.debug.print("{*} mark ", .{obj});
                (Value{ .obj = obj }).print();
                std.debug.print("\n", .{});
            }

            obj.is_marked = true;
        }
    }

    fn markValue(value: Value) void {
        if (value == .obj) markObject(value.obj);
    }

    fn markTable(table: *Table) void {
        var iter = table.iterator();
        while (iter.next()) |entry| {
            markObject(&entry.key_ptr.*.obj);
            markValue(entry.value_ptr.*);
        }
    }

    fn markRoots(self: *@This()) void {
        for (self.roots.stack.items) |slot| {
            markValue(slot);
        }

        markTable(self.roots.globals);
    }

    fn collectGarbage(self: *@This()) void {
        if (comptime config.log_gc) {
            std.debug.print("-- gc begin\n", .{});
        }

        self.markRoots();

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
        // std.debug.print("[alloc] len: {}\n", .{len});

        const self: *@This() = @ptrCast(@alignCast(ctx));

        if (comptime config.stress_gc) {
            self.collectGarbage();
        }

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
        // std.debug.print("[resize] len: {} -> {}, ptr: {*}\n", .{ memory.len, new_len, memory.ptr });

        const self: *@This() = @ptrCast(@alignCast(ctx));

        if (new_len > memory.len) {
            self.collectGarbage();
        }

        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // std.debug.print("[remap] len: {} -> {}, ptr: {*}\n", .{ memory.len, new_len, memory.ptr });

        const self: *@This() = @ptrCast(@alignCast(ctx));

        if (new_len > memory.len) {
            self.collectGarbage();
        }

        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        // std.debug.print("[free] len: {}, ptr: {*}\n", .{ memory.len, memory.ptr });

        const self: *@This() = @ptrCast(@alignCast(ctx));

        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
