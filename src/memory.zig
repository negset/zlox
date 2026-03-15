const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;

pub const GC = struct {
    objects: ?*Obj,

    pub const init = GC{ .objects = null };

    pub fn createObject(self: *GC, allocator: Allocator, T: type) Allocator.Error!*T {
        const ptr = try allocator.create(T);
        switch (T) {
            ObjString => ptr.obj.obj_type = .string,
            else => @panic("Unknown object type."),
        }
        ptr.obj.next = self.objects;
        self.objects = &ptr.obj;
        return ptr;
    }

    pub fn freeObjects(self: *GC, allocator: Allocator) void {
        var object = self.objects;
        var next: ?*Obj = undefined;
        while (object != null) : (object = next) {
            next = object.?.next;
            freeObject(allocator, object.?);
        }
    }

    fn freeObject(allocator: Allocator, obj: *Obj) void {
        switch (obj.obj_type) {
            .string => {
                const obj_string = obj.As(ObjString);
                allocator.free(obj_string.string);
                allocator.destroy(obj_string);
            },
        }
    }
};
