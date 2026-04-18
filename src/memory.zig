const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("object.zig").Obj;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjNative = @import("object.zig").ObjNative;
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

    pub fn deinit(self: *GC, gpa: Allocator) void {
        self.freeObjects(gpa);
        self.globals.deinit(gpa);
        self.strings.deinit(gpa);
    }

    pub fn createObject(self: *GC, gpa: Allocator, comptime T: type) Allocator.Error!*T {
        if (comptime !@hasField(T, "obj")) {
            @compileError("Unknown object type: " ++ @typeName(T));
        }

        const new = try gpa.create(T);
        new.obj.obj_type = T.obj_type;
        new.obj.next = self.objects;
        self.objects = &new.obj;
        return new;
    }

    fn freeObject(gpa: Allocator, obj: *Obj) void {
        switch (obj.obj_type) {
            .function => obj.as(ObjFunction).destory(gpa),
            .native => obj.as(ObjNative).destory(gpa),
            .string => obj.as(ObjString).destroy(gpa),
        }
    }

    pub fn freeObjects(self: *GC, gpa: Allocator) void {
        var object = self.objects;
        var next: ?*Obj = undefined;
        while (object != null) : (object = next) {
            next = object.?.next;
            freeObject(gpa, object.?);
        }
    }

    pub fn findString(self: *GC, string: []const u8, hash: u64) ?*const ObjString {
        return self.strings.getKey(&.{
            .obj = undefined,
            .string = string,
            .hash = hash,
        });
    }
};
