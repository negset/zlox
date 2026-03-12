const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("object.zig").Obj;

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
            .obj => |o| {
                const a = o.As(ObjString).string;
                const b = other.obj.As(ObjString).string;
                return a.len == b.len and std.mem.eql(u8, a, b);
            },
        };
    }

    pub fn isObjType(self: Value, obj_type: ObjType) bool {
        return switch (self) {
            .obj => |obj| obj.obj_type == obj_type,
            else => false,
        }
    }
};
