const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("object.zig").Obj;
const ObjString = @import("object.zig").ObjString;
const ObjStringContext = @import("object.zig").ObjStringContext;
const Value = @import("value.zig").Value;

const Table = std.HashMapUnmanaged(*const ObjString, Value, ObjStringContext, 75);

pub const GC = struct {
    globals: Table,
    strings: Table,
    objects: ?*Obj,

    pub const init = GC{
        .globals = .empty,
        .strings = .empty,
        .objects = null,
    };

    pub fn deinit(self: *GC, allocator: Allocator) void {
        self.freeObjects(allocator);
        self.globals.deinit(allocator);
        self.strings.deinit(allocator);
    }

    pub fn createObject(self: *GC, allocator: Allocator, T: type) Allocator.Error!*T {
        const ptr = try allocator.create(T);
        ptr.obj.obj_type = switch (T) {
            ObjString => .string,
            else => @panic("Unknown object type."),
        };
        ptr.obj.next = self.objects;
        self.objects = &ptr.obj;
        return ptr;
    }

    fn freeObject(allocator: Allocator, obj: *Obj) void {
        switch (obj.obj_type) {
            .string => {
                const obj_string = obj.as(ObjString);
                allocator.free(obj_string.string);
                allocator.destroy(obj_string);
            },
        }
    }

    pub fn freeObjects(self: *GC, allocator: Allocator) void {
        var object = self.objects;
        var next: ?*Obj = undefined;
        while (object != null) : (object = next) {
            next = object.?.next;
            freeObject(allocator, object.?);
        }
    }

    pub fn findString(self: *GC, string: []const u8, hash: u64) ?*const ObjString {
        var obj_string = ObjString{
            .obj = undefined,
            .string = string,
            .hash = hash,
        };
        return self.strings.getKey(&obj_string);
    }
};
