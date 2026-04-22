const std = @import("std");
const Allocator = std.mem.Allocator;
const GC = @import("memory.zig").GC;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjString = @import("object.zig").ObjString;
const Token = @import("scanner.zig").Token;

const Local = struct {
    name: Token,
    // Null if it is uninitialized.
    depth: ?u32,
};

pub const FunctionType = enum {
    function,
    script,
};

pub const Compiler = struct {
    enclosing: ?*Compiler,
    function: ?*ObjFunction,
    function_type: FunctionType,

    locals: [locals_max]Local,
    local_count: u8,
    scope_depth: u32,

    pub const locals_max = std.math.maxInt(u8) + 1;

    pub fn init(
        gpa: Allocator,
        gc: *GC,
        name: ?[]const u8,
        enclosing: ?*Compiler,
        function_type: FunctionType,
    ) Allocator.Error!@This() {
        var new = Compiler{
            .enclosing = enclosing,
            // To prevent GC from collecting uninitialized "function"
            // when calling "ObjFunction.create", set it null beforehand.
            .function = null,
            .function_type = function_type,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
        };
        new.function = try ObjFunction.create(gpa, gc);
        if (function_type != .script) {
            new.function.?.name = try ObjString.createByCopy(gpa, gc, name.?);
        }

        const local = &new.locals[new.local_count];
        new.local_count += 1;
        local.depth = 0;
        local.name.lexeme = "";

        return new;
    }
};
