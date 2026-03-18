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

    fn create(allocator: Allocator, gc: *GC, string: []const u8) Allocator.Error!*ObjString {
        const obj_string = try gc.createObject(allocator, ObjString);
        obj_string.string = string;
        return obj_string;
    }

    pub fn createByCopy(allocator: Allocator, gc: *GC, string: []const u8) Allocator.Error!*ObjString {
        const copied = try allocator.dupe(u8, string);
        return create(allocator, gc, copied);
    }

    pub fn createByTake(allocator: Allocator, gc: *GC, string: []const u8) Allocator.Error!*ObjString {
        return create(allocator, gc, string);
    }
};
