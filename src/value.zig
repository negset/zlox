const std = @import("std");
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;
const config = @import("config");

pub const Value = if (config.nan_boxing) ValueU64 else ValueTaggedUnion;

comptime {
    // TODO: check
    std.debug.assert(@sizeOf(ValueU64) == @sizeOf(u64));
}

const ValueU64 = struct {
    value: u64,

    const sign_bit: u64 = 0x8000_0000_0000_0000;

    // Quiet NaN bit mask.
    // A value with all these bits set is a quiet NaN.
    // Use quiet NaNs to represent non-numeric values,
    // since they can't be the result of erroneous computations.
    const qnan: u64 = 0x7FFF_C000_0000_0000;

    const tag_nil = 0b01;
    const tag_false = 0b10;
    const tag_true = 0b11;

    pub const nil: @This() = .{ .value = qnan | tag_nil };
    pub const @"false": @This() = .{ .value = qnan | tag_false };
    pub const @"true": @This() = .{ .value = qnan | tag_true };

    pub fn fromNumber(num: f64) @This() {
        return .{ .value = @intFromFloat(num) };
    }

    pub fn toNumber(self: @This()) f64 {
        return @floatFromInt(self.value);
    }

    pub fn isNumber(self: @This()) bool {
        return (self.value & qnan) != qnan;
    }

    pub fn isNil(self: @This()) bool {
        return self.value == nil.value;
    }

    pub fn fromBool(b: bool) @This() {
        return if (b) @"true" else @"false";
    }

    pub fn toBool(self: @This()) bool {
        return self.value == @"true".value;
    }

    pub fn isBool(self: @This()) bool {
        // Bitwise OR with 1 converts false to true.
        return self.value | 1 == @"true".value;
    }

    pub fn fromObj(obj: *Obj) @This() {
        return .{ .value = sign_bit | qnan | @as(u64, @intFromPtr(obj)) };
    }

    pub fn toObj(self: @This()) *Obj {
        return @ptrFromInt(self.value & ~(sign_bit | qnan));
    }

    pub fn isObj(self: @This()) bool {
        return self.value & (qnan | sign_bit) == qnan | sign_bit;
    }

    pub fn print(self: @This()) void {
        if (self.isBool()) {
            std.debug.print("{}", .{self.toBool()});
        } else if (self.isNil()) {
            std.debug.print("nil", .{});
        } else if (self.isNumber()) {
            std.debug.print("{}", .{self.toNumber()});
        } else if (self.isObj()) {
            @as(*Obj, @ptrFromInt(self.value)).print();
        }
    }

    pub fn equals(self: @This(), other: @This()) bool {
        // Numbers are compared as numbers, in compliance with
        // the IEEE 754 rule that NaN values are not equal to themselves.
        if (self.isNumber() and other.isNumber()) {
            return self.toNumber() == other.toNumber();
        }
        return self.value == other.value;
    }

    pub fn isFalsey(self: Value) bool {
        return self.isNil() or self.isBool() and !self.toBool();
    }

    pub fn isObjType(self: Value, obj_type: ObjType) bool {
        return if (self.isObj())
            self.toObj().obj_type == obj_type
        else
            false;
    }
};

const ValueTaggedUnion = union(enum) {
    bool: bool,
    nil: void,
    number: f64,
    obj: *Obj,

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
