const std = @import("std");
const Allocator = std.mem.Allocator;
const Obj = @import("object.zig").Obj;
const ObjFunction = @import("object.zig").ObjFunction;
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

    pub fn createObject(self: *GC, allocator: Allocator, comptime T: type) Allocator.Error!*T {
        if (comptime !@hasField(T, "obj")) {
            @compileError("Unknown object type: " ++ @typeName(T));
        }

        const new = try allocator.create(T);
        new.obj.obj_type = T.obj_type;
        new.obj.next = self.objects;
        self.objects = &new.obj;
        return new;
    }

    fn freeObject(allocator: Allocator, obj: *Obj) void {
        switch (obj.obj_type) {
            .function => obj.as(ObjFunction).destory(allocator),
            .string => obj.as(ObjString).destroy(allocator),
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
        return self.strings.getKey(&.{
            .obj = undefined,
            .string = string,
            .hash = hash,
        });
    }
};
