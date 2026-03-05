const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = f64;

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

pub fn print(value: Value) void {
    std.debug.print("{}", .{value});
}
