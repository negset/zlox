const std = @import("std");
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;
const config = @import("config");

pub const Value = if (config.nan_boxing) ValueU64 else ValueTaggedUnion;

const ValueU64 = struct {
    bin: u64,

    const sign_bit: u64 = 0x8000_0000_0000_0000;

    // Quiet NaN bit mask.
    // A value with all these bits set is a quiet NaN.
    // Use quiet NaNs to represent non-numeric values,
    // since they can't be the result of erroneous computations.
    const qnan: u64 = 0x7FFF_C000_0000_0000;

    const tag_nil = 0b01;
    const tag_false = 0b10;
    const tag_true = 0b11;

    pub const nil_value: @This() = .{ .bin = qnan | tag_nil };
    pub const false_value: @This() = .{ .bin = qnan | tag_false };
    pub const true_value: @This() = .{ .bin = qnan | tag_true };

    pub fn init(value: anytype) @This() {
        const T = @TypeOf(value);
        return switch (T) {
            f64 => .{ .bin = @bitCast(value) },
            bool => if (value) true_value else false_value,
            *Obj => .{ .bin = sign_bit | qnan | @intFromPtr(value) },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn as(self: @This(), comptime T: type) T {
        return switch (T) {
            f64 => @bitCast(self.bin),
            bool => self.bin == true_value.bin,
            *Obj => @ptrFromInt(self.bin & ~(sign_bit | qnan)),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn is(self: @This(), comptime T: type) bool {
        return switch (T) {
            f64 => (self.bin & qnan) != qnan,
            void => self.bin == nil_value.bin,
            bool => self.bin | 1 == true_value.bin, // Normalize to true using bitwise OR with 1.
            *Obj => self.bin & (qnan | sign_bit) == qnan | sign_bit,
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn print(self: @This()) void {
        if (self.is(bool)) {
            std.debug.print("{}", .{self.as(bool)});
        } else if (self.is(void)) {
            std.debug.print("nil", .{});
        } else if (self.is(f64)) {
            std.debug.print("{}", .{self.as(f64)});
        } else if (self.is(*Obj)) {
            self.as(*Obj).print();
        }
    }

    pub fn equals(self: @This(), other: @This()) bool {
        // Numbers are compared as numbers, in compliance with
        // the IEEE 754 rule that NaN values are not equal to themselves.
        if (self.is(f64) and other.is(f64)) {
            return self.as(f64) == other.as(f64);
        }
        return self.bin == other.bin;
    }

    pub fn isFalsey(self: @This()) bool {
        return self.is(void) or self.is(bool) and !self.as(bool);
    }

    pub fn isObjType(self: @This(), obj_type: ObjType) bool {
        return if (self.is(*Obj))
            self.as(*Obj).obj_type == obj_type
        else
            false;
    }
};

const ValueTaggedUnion = union(enum) {
    bool: bool,
    nil: void,
    number: f64,
    obj: *Obj,

    pub const nil_value: @This() = .{ .nil = {} };
    pub const false_value: @This() = .{ .bool = false };
    pub const true_value: @This() = .{ .bool = true };

    pub fn init(value: anytype) @This() {
        const T = @TypeOf(value);
        return switch (T) {
            f64 => .{ .number = value },
            bool => .{ .bool = value },
            *Obj => .{ .obj = value },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn as(self: @This(), comptime T: type) T {
        return switch (T) {
            f64 => self.number,
            bool => self.bool,
            *Obj => self.obj,
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn is(self: @This(), comptime T: type) bool {
        return switch (T) {
            f64 => self == .number,
            void => self == .nil,
            bool => self == .bool,
            *Obj => self == .obj,
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    pub fn print(self: @This()) void {
        switch (self) {
            .number => |f| std.debug.print("{}", .{f}),
            .nil => std.debug.print("nil", .{}),
            .bool => |b| std.debug.print("{}", .{b}),
            .obj => |o| o.print(),
        }
    }

    pub fn equals(self: @This(), other: @This()) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .number => |f| f == other.number,
            .bool => |b| b == other.bool,
            .nil => true,
            .obj => |o| o == other.obj,
        };
    }

    pub fn isFalsey(self: @This()) bool {
        return self == .nil or self == .bool and !self.bool;
    }

    pub fn isObjType(self: @This(), obj_type: ObjType) bool {
        return switch (self) {
            .obj => |obj| obj.obj_type == obj_type,
            else => false,
        };
    }
};
