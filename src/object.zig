const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const ObjType = enum {
    string,
};

pub const Obj = struct {
    obj_type: ObjType,

    pub fn As(self: *const Obj, T: type) *const T {
        return @alignCast(@fieldParentPtr("obj", self));
    }

    pub fn print(self: *const Obj) void {
        switch (self.obj_type) {
            .string => std.debug.print("{s}", .{self.As(ObjString).string}),
        }
    }
};

pub const ObjString = struct {
    obj: Obj,
    string: []const u8,

    fn create(allocator: Allocator, string: []const u8) Allocator.Error!*ObjString {
        const obj_string = try allocator.create(ObjString);
        obj_string.obj.obj_type = .string;
        obj_string.string = string;
        return obj_string;
    }

    pub fn createByCopy(allocator: Allocator, string: []const u8) Allocator.Error!*ObjString {
        const copied = try allocator.dupe(u8, string);
        return create(allocator, copied);
    }

    pub fn createByTake(allocator: Allocator, string: []const u8) Allocator.Error!*ObjString {
        return create(allocator, string);
    }
};
