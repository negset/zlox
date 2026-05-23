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
    is_captured: bool,
};

const Upvalue = struct {
    index: u8,
    // Captures a local variable or an existing upvalue.
    is_local: bool,
};

pub const FunctionType = enum {
    function,
    initializer,
    method,
    script,
};

pub const ClassCompiler = struct {
    enclosing: ?*@This(),
    has_superclass: bool,
};

pub const Compiler = struct {
    enclosing: ?*Compiler,
    function: ?*ObjFunction,
    function_type: FunctionType,

    locals: [u8_count]Local,
    local_count: u8,
    upvalues: [u8_count]Upvalue,
    scope_depth: u8,

    pub const u8_count = std.math.maxInt(u8) + 1;

    pub fn init(
        gc: *GC,
        name: ?[]const u8,
        enclosing: ?*Compiler,
        function_type: FunctionType,
    ) Allocator.Error!@This() {
        var new = Compiler{
            .enclosing = enclosing,
            // To prevent GC from dereferencing uninitialized "function" pointer
            // when calling "ObjFunction.create", set it null beforehand.
            .function = null,
            .function_type = function_type,
            .locals = undefined,
            .local_count = 0,
            .upvalues = undefined,
            .scope_depth = 0,
        };
        new.function = try ObjFunction.create(gc);
        if (function_type != .script) {
            // To prevent GC from collecting "function", push it on root.
            try gc.pushRoot(&new.function.?.obj);
            defer gc.popRoot();

            new.function.?.name = try ObjString.createByCopy(gc, name.?);
        }

        const local = &new.locals[new.local_count];
        local.depth = 0;
        local.is_captured = false;
        local.name.lexeme = if (function_type != .function) "this" else "";
        new.local_count += 1;

        return new;
    }
};
