const std = @import("std");
const Allocator = std.mem.Allocator;
const OpCode = @import("chunk.zig").OpCode;
const Compiler = @import("compiler.zig").Compiler;
const Parser = @import("parser.zig").Parser;
const GC = @import("memory.zig").GC;
const Table = @import("memory.zig").Table;
const ObjBoundMethod = @import("object.zig").ObjBoundMethod;
const ObjClass = @import("object.zig").ObjClass;
const ObjClosure = @import("object.zig").ObjClosure;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjInstance = @import("object.zig").ObjInstance;
const ObjNative = @import("object.zig").ObjNative;
const ObjString = @import("object.zig").ObjString;
const ObjUpvalue = @import("object.zig").ObjUpvalue;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const config = @import("config");

pub const CallFrame = struct {
    closure: *ObjClosure,
    ip: usize,
    slots: [*]Value,

    pub fn readByte(self: *CallFrame) u8 {
        defer self.ip += 1;
        return self.closure.function.chunk.code.items[self.ip];
    }

    pub fn readShort(self: *CallFrame) u16 {
        defer self.ip += 2;
        const buf = self.closure.function.chunk.code.items[self.ip..][0..2];
        return std.mem.readInt(u16, buf, .big);
    }

    pub fn readConstant(self: *CallFrame) Value {
        return self.closure.function.chunk.constants.items[self.readByte()];
    }

    pub fn readString(self: *CallFrame) *ObjString {
        return self.readConstant().obj.as(.string);
    }
};

pub const VM = struct {
    gc: GC,
    io: std.Io,
    frames: std.ArrayList(CallFrame),
    stack: std.ArrayList(Value),
    globals: Table,
    open_upvalues: ?*ObjUpvalue,

    const RuntimeError = error{ InvalidOperand, StackOverflow } || Allocator.Error;
    const Error = RuntimeError || Parser.Error;

    const frames_max = 64;
    const stack_max = frames_max * Compiler.u8_count;

    pub fn init(self: *VM, gpa: Allocator, io: std.Io) Allocator.Error!void {
        self.gc = GC.init(gpa);
        self.io = io;

        self.frames = try .initCapacity(self.gc.allocator(), frames_max);
        self.stack = try .initCapacity(self.gc.allocator(), stack_max);
        self.globals = .empty;
        self.open_upvalues = null;

        try self.gc.addRootMarker(self, markVMRoots);

        try self.defineNative("clock", clockNative);
    }

    pub fn deinit(self: *VM) void {
        self.frames.deinit(self.gc.allocator());
        self.stack.deinit(self.gc.allocator());
        self.globals.deinit(self.gc.allocator());
        self.gc.deinit();
    }

    fn clockNative(self: *VM, _: u8, _: [*]Value) Value {
        return Value{ .number = @floatFromInt(std.Io.Clock.real.now(self.io).toSeconds()) };
    }

    fn resetStack(self: *VM) void {
        self.stack.shrinkRetainingCapacity(0);
        self.frames.shrinkRetainingCapacity(0);
        self.open_upvalues = null;
    }

    fn runtimeError(self: *VM, err: RuntimeError, comptime fmt: []const u8, args: anytype) RuntimeError {
        std.debug.print("{s} (runtime): ", .{@errorName(err)});
        std.debug.print(fmt ++ "\n", args);

        for (0..self.frames.items.len) |i| {
            const frame = &self.frames.items[self.frames.items.len - i - 1];
            const function = frame.closure.function;
            const instruction = frame.ip - 1;
            std.debug.print("[line {d}] in ", .{function.chunk.lines.items[instruction]});
            if (function.name) |name| {
                std.debug.print("{s}()\n", .{name.string});
            } else {
                std.debug.print("script\n", .{});
            }
        }

        self.resetStack();
        return err;
    }

    fn defineNative(self: *VM, name: []const u8, native_fn: ObjNative.NativeFn) Allocator.Error!void {
        const obj_string = try ObjString.createByCopy(&self.gc, name);
        // To prevent GC from collecting "obj_string", push it on root.
        try self.gc.pushRoot(&obj_string.obj);
        defer _ = self.gc.popRoot();

        const obj_native = try ObjNative.create(&self.gc, native_fn);
        // To prevent GC from collecting "obj_native", push it on root.
        try self.gc.pushRoot(&obj_native.obj);
        defer _ = self.gc.popRoot();

        try self.globals.put(
            self.gc.allocator(),
            obj_string,
            .{ .obj = &obj_native.obj },
        );
    }

    fn push(self: *VM, value: Value) void {
        self.stack.appendBounded(value) catch @panic("Stack overflow.");
    }

    fn pop(self: *VM) Value {
        return self.stack.pop() orelse @panic("Stack underflow.");
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    fn call(self: *VM, closure: *ObjClosure, arg_count: u8) RuntimeError!void {
        if (arg_count != closure.function.arity) {
            return self.runtimeError(
                error.InvalidOperand,
                "Expected {d} arguments but got {d}.",
                .{ closure.function.arity, arg_count },
            );
        }

        self.frames.appendBounded(.{
            .closure = closure,
            .ip = 0,
            // The frame starts at stack_top - (arg_count + 1),
            // pointing to the function followed by its arguments.
            .slots = (self.stack.items.ptr + self.stack.items.len) - (arg_count + 1),
        }) catch return self.runtimeError(
            error.StackOverflow,
            "Stack overflow.",
            .{},
        );
    }

    fn callValue(self: *VM, callee: Value, arg_count: u8) RuntimeError!void {
        if (callee == .obj) {
            switch (callee.obj.obj_type) {
                .bound_method => {
                    const bound = callee.obj.as(.bound_method);
                    try self.call(bound.method, arg_count);
                    return;
                },
                .class => {
                    const class = callee.obj.as(.class);
                    const instance = try ObjInstance.create(&self.gc, class);
                    const index = self.stack.items.len - 1 - arg_count;
                    self.stack.items[index] = Value{ .obj = &instance.obj };
                    return;
                },
                .closure => {
                    try self.call(callee.obj.as(.closure), arg_count);
                    return;
                },
                .native => {
                    const native = callee.obj.as(.native);
                    const args = self.stack.items.ptr + self.stack.items.len - arg_count;
                    const result = native.native_fn(self, arg_count, args);
                    // Discard args and name of native function.
                    const new_len = self.stack.items.len - arg_count - 1;
                    self.stack.shrinkRetainingCapacity(new_len);
                    self.push(result);
                    return;
                },
                else => {}, // Non-callable object type.
            }
        }
        return self.runtimeError(
            error.InvalidOperand,
            "Can only call functions and classes.",
            .{},
        );
    }

    fn bindMethod(self: *VM, class: *ObjClass, name: *ObjString) Allocator.Error!bool {
        if (class.methods.get(name)) |method| {
            const closure = method.obj.as(.closure);
            // To prevent GC from collecting receiver, use "peek" instead of "pop".
            const bound = try ObjBoundMethod.create(&self.gc, self.peek(0), closure);
            _ = self.pop();
            self.push(Value{ .obj = &bound.obj });
            return true;
        }
        return false;
    }

    fn captureUpvalue(self: *VM, local: [*]Value) Allocator.Error!*ObjUpvalue {
        var previous: ?*ObjUpvalue = null;
        var current: ?*ObjUpvalue = self.open_upvalues;

        while (current) |cur| : (current = cur.next) {
            if (cur.location - local <= 0) break;
            previous = cur;
        }

        if (current) |cur| {
            if (cur.location == local) return cur;
        }

        const new = try ObjUpvalue.create(&self.gc, local);
        new.next = current;

        if (previous) |prev| {
            prev.next = new;
        } else {
            self.open_upvalues = new;
        }

        return new;
    }

    fn closeUpvalues(self: *VM, last: [*]Value) void {
        while (self.open_upvalues) |upvalue| : (self.open_upvalues = upvalue.next) {
            if (upvalue.location - last < 0) break;
            upvalue.closed = upvalue.location[0];
            upvalue.location = @ptrCast(&upvalue.closed);
        }
    }

    fn defineMethod(self: *VM, name: *ObjString) Allocator.Error!void {
        const method = self.peek(0);
        const class = self.peek(1).obj.as(.class);
        try class.methods.put(self.gc.allocator(), name, method);
        // Pop method.
        _ = self.pop();
    }

    fn concatenate(self: *VM) Allocator.Error!void {
        // To prevent GC from collecting "a" and "b", use "peek" insted of "pop".
        const b = self.peek(0).obj.as(.string).string;
        const a = self.peek(1).obj.as(.string).string;

        const string = try std.mem.concat(self.gc.allocator(), u8, &.{ a, b });
        const result = try ObjString.createByTake(&self.gc, string);

        _ = self.pop();
        _ = self.pop();

        self.push(Value{ .obj = &result.obj });
    }

    fn binaryOp(self: *VM, comptime instruction: OpCode) RuntimeError!void {
        if (self.peek(0) != .number or self.peek(1) != .number) {
            return self.runtimeError(
                error.InvalidOperand,
                "Operands must be numbers.",
                .{},
            );
        }
        const b = self.pop().number;
        const a = self.pop().number;

        self.push(switch (comptime instruction) {
            .add => .{ .number = a + b },
            .subtract => .{ .number = a - b },
            .multiply => .{ .number = a * b },
            .divide => .{ .number = a / b },
            .greater => .{ .bool = a > b },
            .less => .{ .bool = a < b },
            else => unreachable,
        });
    }

    fn run(self: *VM) RuntimeError!void {
        var frame = &self.frames.items[self.frames.items.len - 1];

        while (true) {
            if (comptime config.trace_execution) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ ", .{});
                    slot.print();
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});
                _ = debug.disassembleInstruction(&frame.closure.function.chunk, frame.ip);
            }

            switch (@as(OpCode, @enumFromInt(frame.readByte()))) {
                .constant => self.push(frame.readConstant()),
                .nil => self.push(.{ .nil = {} }),
                .true => self.push(.{ .bool = true }),
                .false => self.push(.{ .bool = false }),
                .pop => _ = self.pop(),
                .get_local => {
                    const slot = frame.readByte();
                    self.push(frame.slots[slot]);
                },
                .set_local => {
                    const slot = frame.readByte();
                    frame.slots[slot] = self.peek(0);
                },
                .get_global => {
                    const name = frame.readString();
                    if (self.globals.get(name)) |value| {
                        self.push(value);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Undefined variable '{s}'.",
                        .{name.string},
                    );
                },
                .define_global => {
                    const name = frame.readString();
                    // To prevent GC from collecting the value when calling "globals.put",
                    // use "peek" instead of "pop".
                    try self.globals.put(self.gc.allocator(), name, self.peek(0));
                    _ = self.pop();
                },
                .set_global => {
                    const name = frame.readString();
                    if (self.globals.getPtr(name)) |ptr| {
                        // If exists, overwrite it.
                        ptr.* = self.peek(0);
                    } else return self.runtimeError(
                        error.InvalidOperand,
                        "Undefined variable '{s}'.",
                        .{name.string},
                    );
                },
                .get_upvalue => {
                    const slot = frame.readByte();
                    self.push(frame.closure.upvalues[slot].?.location[0]);
                },
                .set_upvalue => {
                    const slot = frame.readByte();
                    frame.closure.upvalues[slot].?.location[0] = self.peek(0);
                },
                .get_property => {
                    if (!self.peek(0).isObjType(.instance)) {
                        return self.runtimeError(
                            error.InvalidOperand,
                            "Only instances have properties.",
                            .{},
                        );
                    }

                    const instance = self.peek(0).obj.as(.instance);
                    const name = frame.readString();

                    if (instance.fields.get(name)) |value| {
                        _ = self.pop(); // Instance.
                        self.push(value);
                    } else if (!try self.bindMethod(instance.class, name)) {
                        return self.runtimeError(
                            error.InvalidOperand,
                            "Undefined property '{s}'.",
                            .{name.string},
                        );
                    }
                },
                .set_property => {
                    if (!self.peek(1).isObjType(.instance)) {
                        return self.runtimeError(
                            error.InvalidOperand,
                            "Only instances have properties.",
                            .{},
                        );
                    }

                    const instance = self.peek(1).obj.as(.instance);
                    const obj_string = frame.readString();
                    try instance.fields.put(self.gc.allocator(), obj_string, self.peek(0));
                    const value = self.pop();
                    _ = self.pop(); // Instance.
                    self.push(value);
                },
                .equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(.{ .bool = a.equals(b) });
                },
                inline .greater,
                .less,
                .subtract,
                .multiply,
                .divide,
                => |instruction| try self.binaryOp(instruction),
                .add => {
                    if (self.peek(0).isObjType(.string) and self.peek(1).isObjType(.string)) {
                        try self.concatenate();
                    } else if (self.peek(0) == .number and self.peek(1) == .number) {
                        try self.binaryOp(.add);
                    } else {
                        return self.runtimeError(
                            error.InvalidOperand,
                            "Operands must be two numbers or two strings.",
                            .{},
                        );
                    }
                },
                .not => self.push(.{ .bool = self.pop().isFalsey() }),
                .negate => switch (self.peek(0)) {
                    .number => self.push(.{ .number = -(self.pop().number) }),
                    else => return self.runtimeError(
                        error.InvalidOperand,
                        "Operand must be a number.",
                        .{},
                    ),
                },
                .print => {
                    self.pop().print();
                    std.debug.print("\n", .{});
                },
                .jump => {
                    const distance = frame.readShort();
                    frame.ip += distance;
                },
                .jump_if_false => {
                    const distance = frame.readShort();
                    if (self.peek(0).isFalsey()) frame.ip += distance;
                },
                .loop => {
                    const distance = frame.readShort();
                    frame.ip -= distance;
                },
                .call => {
                    const arg_count = frame.readByte();
                    try self.callValue(self.peek(arg_count), arg_count);
                    frame = &self.frames.items[self.frames.items.len - 1];
                },
                .closure => {
                    const function = frame.readConstant().obj.as(.function);
                    const closure = try ObjClosure.create(&self.gc, function);
                    self.push(.{ .obj = &closure.obj });
                    for (0..closure.upvalues.len) |i| {
                        const is_local = frame.readByte();
                        const index = frame.readByte();
                        closure.upvalues[i] = if (is_local != 0)
                            try self.captureUpvalue(frame.slots + index)
                        else
                            frame.closure.upvalues[index];
                    }
                },
                .close_upvalue => {
                    self.closeUpvalues(self.stack.items.ptr + self.stack.items.len - 1);
                    _ = self.pop();
                },
                .@"return" => {
                    const result = self.pop();
                    self.closeUpvalues(frame.slots);

                    const discarded = self.frames.pop() orelse unreachable;
                    if (self.frames.items.len == 0) {
                        // Exit interpreter.
                        _ = self.pop();
                        return;
                    }

                    // Discard call frame.
                    const len = discarded.slots - self.stack.items.ptr;
                    self.stack.shrinkRetainingCapacity(len);
                    self.push(result);
                    frame = &self.frames.items[self.frames.items.len - 1];
                },
                .class => {
                    const name = frame.readString();
                    const class = try ObjClass.create(&self.gc, name);
                    self.push(Value{ .obj = &class.obj });
                },
                .method => {
                    try self.defineMethod(frame.readString());
                },
            }
        }
    }

    pub fn interpret(self: *VM, source: []const u8) Error!void {
        var parser: Parser = undefined;
        try parser.init(source, &self.gc);
        const function = try parser.run();

        // To prevent GC from collecting "function", push it on root.
        try self.gc.pushRoot(&function.obj);
        defer self.gc.popRoot();

        const closure = try ObjClosure.create(&self.gc, function);
        self.push(Value{ .obj = &closure.obj });
        try self.call(closure, 0);

        try self.run();
    }

    fn markVMRoots(ptr: *anyopaque, gc: *GC) void {
        const self: *VM = @ptrCast(@alignCast(ptr));

        for (self.stack.items) |slot| {
            gc.markValue(slot);
        }

        for (self.frames.items) |frame| {
            gc.markObject(&frame.closure.obj);
        }

        var upvalue = self.open_upvalues;
        while (upvalue) |curr| : (upvalue = curr.next) {
            gc.markObject(&curr.obj);
        }

        gc.markTable(&self.globals);
    }
};
