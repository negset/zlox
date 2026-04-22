const std = @import("std");
const Allocator = std.mem.Allocator;
const ObjType = @import("object.zig").ObjType;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;
const Value = @import("value.zig").Value;

pub const GC = struct {
    globals: Table,
    strings: Table,
    objects: ?*Obj,

    const Table = std.HashMapUnmanaged(
        *const ObjString,
        Value,
        ObjString.Context,
        75,
    );

    pub const init = GC{
        .globals = .empty,
        .strings = .empty,
        .objects = null,
    };

    pub fn deinit(self: *GC, gpa: Allocator) void {
        self.freeObjects(gpa);
        self.globals.deinit(gpa);
        self.strings.deinit(gpa);
    }

    pub fn createObject(self: *GC, gpa: Allocator, comptime obj_type: ObjType) Allocator.Error!*obj_type.Impl() {
        const new = try gpa.create(obj_type.Impl());
        new.obj.obj_type = obj_type;
        new.obj.next = self.objects;
        self.objects = &new.obj;
        return new;
    }

    pub fn freeObjects(self: *GC, gpa: Allocator) void {
        var curr = self.objects;
        while (curr) |obj| {
            const next = obj.next;
            obj.destroy(gpa);
            curr = next;
        }
        self.objects = null;
    }

    pub fn findString(self: *GC, string: []const u8, hash: u64) ?*const ObjString {
        return self.strings.getKey(&.{
            .obj = undefined,
            .string = string,
            .hash = hash,
        });
    }
};
