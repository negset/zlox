const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    bool: bool,
    nil: void,
    number: f64,

    pub fn print(self: Value) void {
        switch (self) {
            .number => |f| std.debug.print("{}", .{f}),
            .nil => std.debug.print("nil", .{}),
            .bool => |b| std.debug.print("{}", .{b}),
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .bool => |b| b == other.bool,
            .nil => true,
            .number => |f| f == other.number,
        };
    }
};

pub const ValueArray = struct {
    values: std.ArrayList(Value),

    pub fn init() ValueArray {
        return .{
            .values = .empty,
        };
    }

    pub fn deinit(self: *ValueArray, allocator: Allocator) void {
        self.values.deinit(allocator);
    }

    pub fn write(self: *ValueArray, allocator: Allocator, value: Value) Allocator.Error!void {
        try self.values.append(allocator, value);
    }
};
