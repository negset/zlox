const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const GC = @import("memory.zig").GC;
const Value = @import("value.zig").Value;
const VM = @import("vm.zig").VM;

pub const ObjType = enum {
    function,
    native,
    string,
};

pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,

    pub fn as(self: *const Obj, comptime T: type) *const T {
        const type_ok = @hasDecl(T, "obj_type") and T.obj_type == self.obj_type;
        if (!type_ok) @panic("Invalid type cast: " ++ @typeName(T));

        return @alignCast(@fieldParentPtr("obj", self));
    }

    pub fn print(self: *const Obj) void {
        switch (self.obj_type) {
            .function => self.as(ObjFunction).print(),
            .native => self.as(ObjNative).print(),
            .string => self.as(ObjString).print(),
        }
    }
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u8,
    chunk: Chunk,
    // Null if it is top-level code.
    name: ?*const ObjString,

    pub const obj_type = ObjType.function;

    pub fn create(gpa: Allocator, gc: *GC) Allocator.Error!*@This() {
        const new = try gc.createObject(gpa, @This());
        new.arity = 0;
        new.name = null;
        new.chunk = Chunk.empty;
        return new;
    }

    pub fn destory(self: *const @This(), gpa: Allocator) void {
        var chunk = self.chunk;
        chunk.deinit(gpa);
        gpa.destroy(self);
        // Don't need to free "name" because GC manages it.
    }

    pub fn print(self: *const @This()) void {
        if (self.name) |name| {
            std.debug.print("<fn {s}>", .{name.string});
        } else {
            std.debug.print("<script>", .{});
        }
    }
};

pub const NativeFn = *const fn (vm: *VM, arg_count: u8, args: [*]Value) Value;

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,

    pub const obj_type = ObjType.native;

    pub fn create(gpa: Allocator, gc: *GC, function: NativeFn) Allocator.Error!*@This() {
        const new = try gc.createObject(gpa, @This());
        new.function = function;
        return new;
    }

    pub fn destory(self: *const @This(), gpa: Allocator) void {
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

    pub const obj_type = ObjType.string;

    fn create(gpa: Allocator, gc: *GC, string: []const u8, hash: u64) Allocator.Error!*const @This() {
        const new = try gc.createObject(gpa, @This());
        new.string = string;
        new.hash = hash;
        try gc.strings.put(gpa, new, Value{ .nil = {} });
        return new;
    }

    pub fn createByCopy(gpa: Allocator, gc: *GC, string: []const u8) Allocator.Error!*const @This() {
        const hash = std.hash.Fnv1a_64.hash(string);
        if (gc.findString(string, hash)) |interned| {
            return interned;
        }

        const copied = try gpa.dupe(u8, string);
        return create(gpa, gc, copied, hash);
    }

    pub fn createByTake(gpa: Allocator, gc: *GC, string: []const u8) Allocator.Error!*const @This() {
        const hash = std.hash.Fnv1a_64.hash(string);
        if (gc.findString(string, hash)) |interned| {
            gpa.free(string);
            return interned;
        }

        return create(gpa, gc, string, hash);
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
