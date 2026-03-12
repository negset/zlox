const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

const ObjType = enum {
    string,
};

pub const Obj = struct {
    obj_type: ObjType,

    pub fn create(allocator: Allocator, obj_type: ObjType) Allocator.Error!*const Obj {
        const T = switch (obj_type) {
            .string => ObjString,
        };
        const obj = try allocater.create(T);
        obj.obj_type = obj_type;
        return obj;
    }

    pub fn As(self: *const Obj, T: type) *const T {
        return @fielsParentPtr("obj", self);
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

    pub fn create(allocator: Allocator, string: []const u8) Allocator.Error!*const ObjString {
        const copied = try allocator.dupe(u8, string);
        return allocateString(copied);
    }

    fn allocateString(allocator: Allocator, string: []const u8) *const ObjString {
        const obj_string = Obj.create(allocater, .string);
        obj_string.string = string;
        return obj_string;
    }
};
