const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const GC = @import("memory.zig").GC;
const Value = @import("value.zig").Value;

pub const ObjType = enum {
    function,
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
            .string => self.as(ObjString).print(),
        }
    }
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u32,
    chunk: Chunk,
    name: ?*const ObjString,

    pub const obj_type = ObjType.function;

    pub fn create(allocator: Allocator, gc: *GC) Allocator.Error!*const @This() {
        const new = try gc.createObject(allocator, @This());
        new.arity = 0;
        new.name = null;
        new.chunk = Chunk.empty;
        return new;
    }

    pub fn destory(self: *const @This(), allocator: Allocator) void {
        var chunk = self.chunk;
        chunk.deinit(allocator);
        allocator.destroy(self);
        // Don't need to free "name" because GC manages it.
    }

    pub fn print(self: @This()) void {
        std.debug.print("<fn {s}>", .{self.name.?.string});
    }
};

pub const ObjString = struct {
    obj: Obj,
    string: []const u8,
    hash: u64,

    pub const obj_type = ObjType.string;

    fn create(allocator: Allocator, gc: *GC, string: []const u8, hash: u64) Allocator.Error!*const @This() {
        const new = try gc.createObject(allocator, @This());
        new.string = string;
        new.hash = hash;
        try gc.strings.put(allocator, new, Value{ .nil = {} });
        return new;
    }

    pub fn createByCopy(allocator: Allocator, gc: *GC, string: []const u8) Allocator.Error!*const @This() {
        const hash = std.hash.Fnv1a_64.hash(string);
        if (gc.findString(string, hash)) |interned| {
            return interned;
        }

        const copied = try allocator.dupe(u8, string);
        return create(allocator, gc, copied, hash);
    }

    pub fn createByTake(allocator: Allocator, gc: *GC, string: []const u8) Allocator.Error!*const @This() {
        const hash = std.hash.Fnv1a_64.hash(string);
        if (gc.findString(string, hash)) |interned| {
            allocator.free(string);
            return interned;
        }

        return create(allocator, gc, string, hash);
    }

    pub fn destroy(self: *const @This(), allocator: Allocator) void {
        allocator.free(self.string);
        allocator.destroy(self);
    }

    pub fn print(self: *const @This()) void {
        std.debug.print("{s}", .{self.string});
    }
};

pub const ObjStringContext = struct {
    pub fn hash(_: @This(), obj_string: *const ObjString) u64 {
        return obj_string.hash;
    }

    pub fn eql(_: @This(), a: *const ObjString, b: *const ObjString) bool {
        if (a == b) return true;
        if (a.string.len != b.string.len) return false;
        return std.mem.eql(u8, a.string, b.string);
    }
};
