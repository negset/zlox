const std = @import("std");
const Allocator = std.mem.Allocator;
const GC = @import("memory.zig").GC;
const Value = @import("value.zig").Value;

pub const ObjType = enum {
    string,
};

pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,

    pub fn as(self: *const Obj, comptime T: type) *const T {
        const type_ok = switch (comptime self.obj_type) {
            .string => T == ObjString,
        };
        if (!type_ok) @compileError("Invalid type cast: " ++ @typeName(T));

        return @alignCast(@fieldParentPtr("obj", self));
    }

    pub fn print(self: *const Obj) void {
        switch (self.obj_type) {
            .string => std.debug.print("{s}", .{self.as(ObjString).string}),
        }
    }
};

pub const ObjString = struct {
    obj: Obj,
    string: []const u8,
    hash: u64,

    fn create(allocator: Allocator, gc: *GC, string: []const u8, hash: u64) Allocator.Error!*const @This() {
        const obj_string = try gc.createObject(allocator, @This());
        obj_string.obj.obj_type = .string;
        obj_string.string = string;
        obj_string.hash = hash;
        try gc.strings.put(allocator, obj_string, Value{ .nil = {} });
        return obj_string;
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

    pub fn destroy(self: *const ObjString, allocator: Allocator) void {
        allocator.free(self.string);
        allocator.destroy(self);
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
