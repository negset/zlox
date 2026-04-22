const std = @import("std");
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;

pub const Value = union(enum) {
    bool: bool,
    nil: void,
    number: f64,
    obj: *const Obj,

    pub fn print(self: Value) void {
        switch (self) {
            .number => |f| std.debug.print("{}", .{f}),
            .nil => std.debug.print("nil", .{}),
            .bool => |b| std.debug.print("{}", .{b}),
            .obj => |o| o.print(),
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .bool => |b| b == other.bool,
            .nil => true,
            .number => |f| f == other.number,
            .obj => |o| o == other.obj,
        };
    }

    pub fn isFalsey(self: Value) bool {
        return self == .nil or (self == .bool and !self.bool);
    }

    pub fn isObjType(self: Value, obj_type: ObjType) bool {
        return switch (self) {
            .obj => |obj| obj.obj_type == obj_type,
            else => false,
        };
    }
};
