const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const GC = @import("memory.zig").GC;
const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

pub const ObjType = enum {
    closure,
    function,
    native,
    string,
    upvalue,

    pub fn Impl(comptime obj_type: ObjType) type {
        return switch (obj_type) {
            .closure => ObjClosure,
            .function => ObjFunction,
            .native => ObjNative,
            .string => ObjString,
            .upvalue => ObjUpvalue,
        };
    }
};

pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,

    pub fn as(self: *const Obj, comptime obj_type: ObjType) *const obj_type.Impl() {
        if (self.obj_type != obj_type) @panic("Invalid Obj cast.");
        return @ptrCast(self);
    }

    pub fn destroy(self: *const Obj, gpa: Allocator) void {
        switch (self.obj_type) {
            inline else => |obj_type| {
                self.as(obj_type).destroy(gpa);
            },
        }
    }

    pub fn print(self: *const Obj) void {
        switch (self.obj_type) {
            inline else => |obj_type| {
                self.as(obj_type).print();
            },
        }
    }
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *const ObjFunction,
    upvalues: []?*ObjUpvalue,

    pub fn create(gc: *GC, function: *const ObjFunction) Allocator.Error!*@This() {
        const upvalues = try gc.allocator().alloc(?*ObjUpvalue, function.upvalue_count);
        // Ensure GC never sees uninitialized memory.
        for (upvalues) |*upvalue| {
            upvalue.* = null;
        }

        const new = try gc.createObject(.closure);
        new.function = function;
        new.upvalues = upvalues;
        return new;
    }

    pub fn destroy(self: *const @This(), gpa: Allocator) void {
        gpa.free(self.upvalues);
        gpa.destroy(self);
        // Don't free "function" because closure does'nt own it.
    }

    pub fn print(self: *const @This()) void {
        self.function.print();
    }
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u8,
    upvalue_count: u8,
    chunk: Chunk,
    // Null if it is top-level code.
    name: ?*const ObjString,

    pub fn create(gc: *GC) Allocator.Error!*@This() {
        const new = try gc.createObject(.function);
        new.arity = 0;
        new.upvalue_count = 0;
        new.name = null;
        new.chunk = Chunk.empty;
        return new;
    }

    pub fn destroy(self: *const @This(), gpa: Allocator) void {
        var chunk = self.chunk;
        chunk.deinit(gpa);
        gpa.destroy(self);
        // Don't free "name" because GC manages it.
    }

    pub fn print(self: *const @This()) void {
        if (self.name) |name| {
            std.debug.print("<fn {s}>", .{name.string});
        } else {
            std.debug.print("<script>", .{});
        }
    }
};

pub const ObjNative = struct {
    obj: Obj,
    native_fn: NativeFn,

    pub const NativeFn = *const fn (vm: *VM, arg_count: u8, args: [*]Value) Value;

    pub fn create(gc: *GC, native_fn: NativeFn) Allocator.Error!*const @This() {
        const new = try gc.createObject(.native);
        new.native_fn = native_fn;
        return new;
    }

    pub fn destroy(self: *const @This(), gpa: Allocator) void {
        gpa.destroy(self);
    }

    pub fn print(_: *const @This()) void {
        std.debug.print("<native fn>", .{});
    }
};

pub const ObjString = struct {
    obj: Obj,
    string: []const u8,
    hash: u64,

    fn create(gc: *GC, string: []const u8, hash: u64) Allocator.Error!*const @This() {
        const new = try gc.createObject(.string);
        new.string = string;
        new.hash = hash;
        try gc.strings.put(gc.allocator(), new, Value{ .nil = {} });
        return new;
    }

    pub fn createByCopy(gc: *GC, string: []const u8) Allocator.Error!*const @This() {
        const hash = std.hash.Fnv1a_64.hash(string);
        if (gc.findString(string, hash)) |interned| {
            return interned;
        }

        const copied = try gc.allocator().dupe(u8, string);
        return create(gc, copied, hash);
    }

    pub fn createByTake(gc: *GC, string: []const u8) Allocator.Error!*const @This() {
        const hash = std.hash.Fnv1a_64.hash(string);
        if (gc.findString(string, hash)) |interned| {
            gc.allocator().free(string);
            return interned;
        }

        return create(gc, string, hash);
    }

    pub fn destroy(self: *const @This(), gpa: Allocator) void {
        gpa.free(self.string);
        gpa.destroy(self);
    }

    pub fn print(self: *const @This()) void {
        std.debug.print("{s}", .{self.string});
    }

    pub const Context = struct {
        pub fn hash(_: @This(), obj_string: *const ObjString) u64 {
            return obj_string.hash;
        }

        pub fn eql(_: @This(), a: *const ObjString, b: *const ObjString) bool {
            if (a == b) return true;
            if (a.string.len != b.string.len) return false;
            return std.mem.eql(u8, a.string, b.string);
        }
    };
};

pub const ObjUpvalue = struct {
    obj: Obj,
    location: [*]Value,
    closed: Value,
    next: ?*@This(),

    pub fn create(gc: *GC, slot: [*]Value) Allocator.Error!*@This() {
        const new = try gc.createObject(.upvalue);
        new.closed = .{ .nil = {} };
        new.location = slot;
        new.next = null;
        return new;
    }

    pub fn destroy(self: *const @This(), gpa: Allocator) void {
        gpa.destroy(self);
    }

    pub fn print(_: *const @This()) void {
        // Users can't print upvalues since they are not first-class values.
        unreachable;
    }
};
