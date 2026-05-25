const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const Compiler = @import("compiler.zig").Compiler;
const ObjType = @import("object.zig").ObjType;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;
const ObjUpvalue = @import("object.zig").ObjUpvalue;
const Value = @import("value.zig").Value;
const CallFrame = @import("vm.zig").CallFrame;
const config = @import("config");

pub const Table = std.HashMapUnmanaged(
    *ObjString,
    Value,
    ObjString.Context,
    75,
);

const MarkFn = *const fn (ptr: *anyopaque, gc: *GC) void;

pub const RootMarker = struct {
    ptr: *anyopaque,
    mark_fn: MarkFn,
};

pub const GC = struct {
    backing: Allocator,
    strings: Table,
    objects: ?*Obj,
    temp_root: std.ArrayList(*Obj),
    markers: std.ArrayList(RootMarker),
    gray_stack: std.ArrayList(*Obj),
    bytes_allocated: usize,
    next_gc: usize,

    const heap_grow_factor = 2;

    pub fn init(backing: Allocator) @This() {
        return .{
            .backing = backing,
            .strings = .empty,
            .objects = null,
            .markers = .empty,
            .gray_stack = .empty,
            .bytes_allocated = 0,
            .next_gc = 1024 * 1024,
            .temp_root = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.freeObjects();
        self.strings.deinit(self.allocator());
        self.markers.deinit(self.backing);
        self.gray_stack.deinit(self.backing);
        self.temp_root.deinit(self.backing);
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
            std.debug.print("0x{x} allocate {} for {}\n", .{ @intFromPtr(new), @sizeOf(obj_type.Impl()), obj_type });
        }

        return new;
    }

    pub fn freeObjects(self: *@This()) void {
        var curr = self.objects;
        var next: ?*Obj = null;
        while (curr) |obj| : (curr = next) {
            next = obj.next;
            obj.destroy(self.allocator());
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

    pub fn pushRoot(self: *@This(), object: *Obj) Allocator.Error!void {
        // "temp_root" uses backing instead of allocator(),
        // to prevent the GC from recursively starting a new GC.
        try self.temp_root.append(self.backing, object);
    }

    pub fn popRoot(self: *@This()) void {
        _ = self.temp_root.pop();
    }

    pub fn addRootMarker(self: *@This(), ptr: *anyopaque, mark_fn: MarkFn) Allocator.Error!void {
        // "markers" uses backing instead of allocator(),
        // because memory allocation can trigger a scan of markers.
        try self.markers.append(self.backing, .{ .ptr = ptr, .mark_fn = mark_fn });
    }

    pub fn markObject(self: *@This(), object: ?*Obj) void {
        if (object) |obj| {
            if (obj.is_marked) return;

            if (comptime config.log_gc) {
                std.debug.print("0x{x} mark ", .{@intFromPtr(obj)});
                obj.print();
                std.debug.print("\n", .{});
            }

            obj.is_marked = true;

            // "gray_stack" uses backing instead of allocator(),
            // to prevent the GC from recursively starting a new GC.
            self.gray_stack.append(self.backing, obj) catch |err| @panic(@errorName(err));
        }
    }

    pub fn markValue(self: *@This(), value: Value) void {
        if (value.isObj()) self.markObject(value.toObj());
    }

    pub fn markArray(self: *@This(), array: std.ArrayList(Value)) void {
        for (array.items) |value| {
            self.markValue(value);
        }
    }

    pub fn markTable(self: *@This(), table: *Table) void {
        var iter = table.iterator();
        while (iter.next()) |entry| {
            self.markObject(&entry.key_ptr.*.obj);
            self.markValue(entry.value_ptr.*);
        }
    }

    pub fn markCompilers(self: *@This(), compiler: ?*Compiler) void {
        var current = compiler;
        while (current) |curr| : (current = curr.enclosing) {
            self.markObject(&curr.function.?.obj);
        }
    }

    fn markRoots(self: *@This()) void {
        for (self.markers.items) |marker| {
            marker.mark_fn(marker.ptr, self);
        }

        for (self.temp_root.items) |object| {
            self.markObject(object);
        }
    }

    fn blackenObject(self: *@This(), object: *Obj) void {
        if (comptime config.log_gc) {
            std.debug.print("0x{x} blacken ", .{@intFromPtr(object)});
            object.print();
            std.debug.print("\n", .{});
        }

        switch (object.obj_type) {
            .bound_method => {
                const bound = object.as(.bound_method);
                self.markValue(bound.receiver);
                self.markObject(&bound.method.obj);
            },
            .class => {
                const class = object.as(.class);
                self.markObject(&class.name.obj);
                self.markTable(&class.methods);
            },
            .closure => {
                const closure = object.as(.closure);
                self.markObject(&closure.function.obj);
                for (closure.upvalues) |upvalue| {
                    if (upvalue) |u| self.markObject(&u.obj);
                }
            },
            .function => {
                const function = object.as(.function);
                if (function.name) |name| self.markObject(&name.obj);
                self.markArray(function.chunk.constants);
            },
            .instance => {
                const instance = object.as(.instance);
                self.markObject(&instance.class.obj);
                self.markTable(&instance.fields);
            },
            .upvalue => self.markValue(object.as(.upvalue).closed),
            .native, .string => {}, // It has no outgoing references.
        }
    }

    fn traceReferences(self: *@This()) void {
        while (self.gray_stack.items.len > 0) {
            const object = self.gray_stack.pop() orelse unreachable;
            self.blackenObject(object);
        }
    }

    fn sweep(self: *@This()) void {
        var prev: ?*Obj = null;
        var object = self.objects;
        while (object) |curr| {
            if (curr.is_marked) {
                curr.is_marked = false;
                prev = curr;
                object = curr.next;
            } else {
                object = curr.next;
                if (prev) |p| {
                    p.next = object;
                } else {
                    self.objects = object;
                }

                curr.destroy(self.allocator());
            }
        }
    }

    fn tableRemoveWhite(table: *Table) void {
        var iter = table.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!key.obj.is_marked) {
                _ = table.remove(key);
            }
        }
    }

    fn collectGarbage(self: *@This()) void {
        if (comptime config.log_gc) {
            std.debug.print("-- gc begin\n", .{});
        }
        const before = self.bytes_allocated;

        self.markRoots();
        self.traceReferences();
        tableRemoveWhite(&self.strings);
        self.sweep();

        self.next_gc = self.bytes_allocated * heap_grow_factor;

        if (comptime config.log_gc) {
            std.debug.print("-- gc end\n", .{});
            std.debug.print(
                "   collected {} bytes (from {} to {}) next at {}\n",
                .{ before - self.bytes_allocated, before, self.bytes_allocated, self.next_gc },
            );
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
        self.bytes_allocated += len;
        if ((comptime config.stress_gc) or self.bytes_allocated > self.next_gc) {
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
        self.bytes_allocated += new_len - memory.len;
        if (new_len > memory.len) {
            if ((comptime config.stress_gc) or self.bytes_allocated > self.next_gc) {
                self.collectGarbage();
            }
        }

        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // std.debug.print("[remap] len: {} -> {}, ptr: {*}\n", .{ memory.len, new_len, memory.ptr });

        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.bytes_allocated += new_len - memory.len;
        if (new_len > memory.len) {
            if ((comptime config.stress_gc) or self.bytes_allocated > self.next_gc) {
                self.collectGarbage();
            }
        }

        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        // std.debug.print("[free] len: {}, ptr: {*}\n", .{ memory.len, memory.ptr });

        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.bytes_allocated -= memory.len;

        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
