const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Compiler = @import("compiler.zig").Compiler;
const ClassCompiler = @import("compiler.zig").ClassCompiler;
const FunctionType = @import("compiler.zig").FunctionType;
const GC = @import("memory.zig").GC;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjString = @import("object.zig").ObjString;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const config = @import("config");

const Precedence = enum {
    none,
    assignment, // =
    @"or", // or
    @"and", // and
    equality, // == !=
    comparison, // < > <= >=
    term, // + -
    factor, // * /
    unary, // ! -
    call, // . ()
    primary,

    pub fn next(self: Precedence) Precedence {
        return @enumFromInt(@intFromEnum(self) + 1);
    }

    pub fn le(self: Precedence, other: Precedence) bool {
        return @intFromEnum(self) <= @intFromEnum(other);
    }
};

const ParseFn = *const fn (*Parser, bool) Allocator.Error!void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence = .none,
};

pub const Parser = struct {
    scanner: Scanner,
    compiler: ?*Compiler,
    class_compiler: ?*ClassCompiler,
    gc: *GC,
    current: Token,
    previous: Token,
    err: ?Error,
    panic_mode: bool,

    pub const Error = error{
        InvalidSyntax,
        TooManyElements,
    } || Allocator.Error;

    pub fn init(self: *Parser, source: []const u8, gc: *GC) Allocator.Error!void {
        self.scanner = .init(source);
        self.compiler = null;
        self.class_compiler = null;
        self.gc = gc;
        self.err = null;
        self.panic_mode = false;

        try gc.addRootMarker(self, markParserRoots);
    }

    fn currentChunk(self: *Parser) *Chunk {
        return &self.compiler.?.function.?.chunk;
    }

    fn errorAt(self: *Parser, token: Token, err: Error, message: []const u8) void {
        if (self.panic_mode) return;
        self.panic_mode = true;

        std.debug.print("[line {d}] {s} (comptime)", .{ token.line, @errorName(err) });

        switch (token.token_type) {
            .eof => std.debug.print(" at end", .{}),
            .@"error" => {}, // Nothing.
            else => std.debug.print(" at '{s}'", .{token.lexeme}),
        }

        std.debug.print(": {s}\n", .{message});

        self.err = err;
    }

    fn errorAtPrevious(self: *Parser, err: Error, message: []const u8) void {
        errorAt(self, self.previous, err, message);
    }

    fn errorAtCurrent(self: *Parser, err: Error, message: []const u8) void {
        errorAt(self, self.current, err, message);
    }

    pub fn advance(self: *Parser) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scanToken();
            if (self.current.token_type != .@"error") break;

            self.errorAtCurrent(error.InvalidSyntax, self.current.lexeme);
        }
    }

    pub fn consume(self: *Parser, token_type: TokenType, message: []const u8) void {
        if (self.current.token_type == token_type) {
            self.advance();
            return;
        }

        self.errorAtCurrent(error.InvalidSyntax, message);
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        return self.current.token_type == token_type;
    }

    pub fn match(self: *Parser, token_type: TokenType) bool {
        if (!self.check(token_type)) return false;
        self.advance();
        return true;
    }

    fn emit(self: *Parser, data: anytype) Allocator.Error!void {
        const T = @TypeOf(data);
        switch (@typeInfo(T)) {
            .int => {
                if (T != u8) @compileError("Incompatible int type to emit: " ++ @typeName(T));
                try self.currentChunk().write(self.gc.allocator(), @intCast(data), self.previous.line);
            },
            .@"enum" => {
                if (T != OpCode) @compileError("Incompatible enum type to emit: " ++ @typeName(T));
                try self.currentChunk().write(self.gc.allocator(), @intFromEnum(data), self.previous.line);
            },
            .@"struct" => |s| {
                inline for (s.fields) |field| {
                    try self.emit(@field(data, field.name));
                }
            },
            else => @compileError("Incompatible type to emit: " ++ @typeName(T)),
        }
    }

    fn emitLoop(self: *Parser, loop_start: usize) Allocator.Error!void {
        try self.emit(OpCode.loop);

        // +2 to take into account the loop distance itself.
        const distance = self.currentChunk().code.items.len - loop_start + 2;
        if (distance > std.math.maxInt(u16)) {
            self.errorAtPrevious(
                error.TooManyElements,
                "Loop body too large.",
            );
        }

        try self.emit(.{ @as(u8, @truncate(distance >> 8)), @as(u8, @truncate(distance)) });
    }

    fn emitJump(self: *Parser, instruction: OpCode) Allocator.Error!usize {
        // Emit with temporary jump distance.
        try self.emit(.{ instruction, @as(u8, 0xff), @as(u8, 0xff) });
        // Return offset of jump distance.
        return self.currentChunk().code.items.len - 2;
    }

    fn emitReturn(self: *Parser) Allocator.Error!void {
        if (self.compiler.?.function_type == .initializer) {
            // Return instance stored in slot zero.
            try self.emit(.{ OpCode.get_local, @as(u8, 0), OpCode.@"return" });
        } else {
            try self.emit(.{ OpCode.nil, OpCode.@"return" });
        }
    }

    fn makeConstant(self: *Parser, value: Value) Allocator.Error!u8 {
        // To prevent GC from collecting "value", push it on root.
        if (value == .obj) try self.gc.pushRoot(value.obj);
        defer {
            if (value == .obj) self.gc.popRoot();
        }

        const index = try self.currentChunk().addConstant(self.gc.allocator(), value);
        // Make sure the chunk does not contain too many constants,
        // since OpCode.constant uses a single byte for its index operand.
        if (std.math.cast(u8, index)) |byte| {
            return byte;
        } else {
            self.errorAtPrevious(
                error.TooManyElements,
                "Too many constants in one chunk.",
            );
            return 0;
        }
    }

    fn emitConstant(self: *Parser, value: Value) Allocator.Error!void {
        const constant = try self.makeConstant(value);
        try self.emit(.{ OpCode.constant, constant });
    }

    fn patchJump(self: *Parser, target: usize) void {
        // -2 to take into account the jump distance itself.
        const distance = self.currentChunk().code.items.len - target - 2;

        if (distance > std.math.maxInt(u16)) {
            self.errorAtPrevious(
                error.TooManyElements,
                "Too much code to jump over.",
            );
        }

        // Patch jump distance into previously emitted one.
        const buf = self.currentChunk().code.items[target..][0..2];
        std.mem.writeInt(u16, buf, @intCast(distance), .big);
    }

    pub fn endCompiler(self: *Parser) Allocator.Error!*ObjFunction {
        try self.emitReturn();
        const obj_function = self.compiler.?.function.?;

        if (comptime config.print_code) {
            const name = if (obj_function.name) |n| n.string else "<script>";
            debug.disassembleChunk(self.currentChunk(), name);
        }

        self.compiler = self.compiler.?.enclosing;
        return obj_function;
    }

    pub fn beginScope(self: *Parser) void {
        self.compiler.?.scope_depth += 1;
    }

    pub fn endScope(self: *Parser) Allocator.Error!void {
        const c = self.compiler.?;
        c.scope_depth -= 1;

        while (c.local_count > 0 and c.locals[c.local_count - 1].depth.? > c.scope_depth) : (c.local_count -= 1) {
            if (c.locals[c.local_count - 1].is_captured) {
                try self.emit(OpCode.close_upvalue);
            } else {
                try self.emit(OpCode.pop);
            }
        }
    }

    fn identifierConstant(self: *Parser, name: Token) Allocator.Error!u8 {
        const obj_string = try ObjString.createByCopy(self.gc, name.lexeme);
        return self.makeConstant(.{ .obj = &obj_string.obj });
    }

    fn resolveLocal(self: *Parser, compiler: *Compiler, name: Token) ?u8 {
        for (0..compiler.local_count) |i| {
            const slot = compiler.local_count - i - 1;
            const local = &compiler.locals[slot];
            if (name.identifierEquals(local.name)) {
                if (local.depth == null) {
                    self.errorAtPrevious(
                        error.InvalidSyntax,
                        "Can't read local variable in its own initializer.",
                    );
                }
                return @intCast(slot);
            }
        }

        return null;
    }

    fn addUpvalue(self: *Parser, compiler: *Compiler, index: u8, is_local: bool) u8 {
        const upvalue_count = compiler.function.?.upvalue_count;

        // Check if function already has upvalue that closes over that variable.
        for (0..upvalue_count) |i| {
            const upvalue = &compiler.upvalues[i];
            if (upvalue.index == index and upvalue.is_local == is_local) {
                return @intCast(i);
            }
        }

        if (upvalue_count == Compiler.u8_count) {
            self.errorAtPrevious(
                error.TooManyElements,
                "Too many closure variables in function.",
            );
        }

        compiler.upvalues[upvalue_count] = .{
            .is_local = is_local,
            .index = index,
        };
        compiler.function.?.upvalue_count += 1;
        return upvalue_count;
    }

    fn resolveUpvalue(self: *Parser, compiler: *Compiler, name: Token) ?u8 {
        if (compiler.enclosing) |enclosing| {
            if (self.resolveLocal(enclosing, name)) |local| {
                enclosing.locals[local].is_captured = true;
                return self.addUpvalue(compiler, local, true);
            }

            if (self.resolveUpvalue(enclosing, name)) |upvalue| {
                return self.addUpvalue(compiler, upvalue, false);
            }
        }

        return null;
    }

    fn addLocal(self: *Parser, name: Token) void {
        const c = self.compiler.?;

        if (c.local_count == Compiler.u8_count) {
            self.errorAtPrevious(
                error.TooManyElements,
                "Too many local variables in function.",
            );
        }

        defer c.local_count += 1;
        const local = &c.locals[c.local_count];
        local.* = .{
            .name = name,
            .depth = null,
            .is_captured = false,
        };
    }

    fn declareVariable(self: *Parser) void {
        const c = self.compiler.?;

        // Skip global variable.
        if (c.scope_depth == 0) return;

        const name = self.previous;
        for (0..c.local_count) |i| {
            const local = &c.locals[c.local_count - i - 1];
            if (local.depth) |depth| {
                if (depth < c.scope_depth) break;
            }

            if (name.identifierEquals(local.name)) {
                self.errorAtPrevious(
                    error.InvalidSyntax,
                    "Already a variable with this name in this scope.",
                );
            }
        }

        self.addLocal(name);
    }

    fn parseVariable(self: *Parser, message: []const u8) Allocator.Error!u8 {
        self.consume(.identifier, message);

        self.declareVariable();
        // If in a local scope, return dummy index.
        if (self.compiler.?.scope_depth > 0) return 0;

        return self.identifierConstant(self.previous);
    }

    fn markInitialized(self: *Parser) void {
        const c = self.compiler.?;
        // Skip global.
        if (c.scope_depth == 0) return;
        c.locals[c.local_count - 1].depth = c.scope_depth;
    }

    fn defineVariable(self: *Parser, global: u8) Allocator.Error!void {
        // If in a local scope, use stack value as a local variable.
        if (self.compiler.?.scope_depth > 0) {
            self.markInitialized();
            return;
        }

        try self.emit(.{ OpCode.define_global, global });
    }

    fn argumentList(self: *Parser) Allocator.Error!u8 {
        var arg_count: u8 = 0;
        if (!self.check(.right_paren)) {
            while (true) {
                try self.expression();
                if (arg_count == 255) {
                    self.errorAtPrevious(
                        error.TooManyElements,
                        "Can't have more than 255 arguments.",
                    );
                }
                arg_count += 1;
                if (!self.match(.comma)) break;
            }
        }
        self.consume(.right_paren, "Expect ')' after arguments.");
        return arg_count;
    }

    fn @"and"(self: *Parser, _: bool) Allocator.Error!void {
        const end_jump = try self.emitJump(.jump_if_false);

        // Discard the left operand when it is truthy.
        try self.emit(OpCode.pop);
        try self.parsePrecedence(.@"and");

        self.patchJump(end_jump);
    }

    fn binary(self: *Parser, _: bool) Allocator.Error!void {
        const operator_type = self.previous.token_type;
        const rule = getRule(operator_type);
        try self.parsePrecedence(rule.precedence.next());
        switch (operator_type) {
            .minus => try self.emit(OpCode.subtract),
            .plus => try self.emit(OpCode.add),
            .slash => try self.emit(OpCode.divide),
            .star => try self.emit(OpCode.multiply),
            .bang_equal => try self.emit(.{ OpCode.equal, OpCode.not }),
            .equal_equal => try self.emit(OpCode.equal),
            .greater => try self.emit(OpCode.greater),
            .greater_equal => try self.emit(.{ OpCode.less, OpCode.not }),
            .less => try self.emit(OpCode.less),
            .less_equal => try self.emit(.{ OpCode.greater, OpCode.not }),
            else => unreachable,
        }
    }

    fn call(self: *Parser, _: bool) Allocator.Error!void {
        const arg_count = try self.argumentList();
        try self.emit(.{ OpCode.call, arg_count });
    }

    fn dot(self: *Parser, can_assign: bool) Allocator.Error!void {
        self.consume(.identifier, "Expect property name after '.'.");
        const name = try self.identifierConstant(self.previous);

        if (can_assign and self.match(.equal)) {
            try self.expression();
            try self.emit(.{ OpCode.set_property, name });
        } else if (self.match(.left_paren)) {
            const arg_count = try self.argumentList();
            try self.emit(.{ OpCode.invoke, name, arg_count });
        } else {
            try self.emit(.{ OpCode.get_property, name });
        }
    }

    fn literal(self: *Parser, _: bool) Allocator.Error!void {
        switch (self.previous.token_type) {
            .false => try self.emit(OpCode.false),
            .nil => try self.emit(OpCode.nil),
            .true => try self.emit(OpCode.true),
            else => unreachable,
        }
    }

    fn grouping(self: *Parser, _: bool) Allocator.Error!void {
        try self.expression();
        self.consume(.right_paren, "Expect ')' after expression.");
    }

    fn number(self: *Parser, _: bool) Allocator.Error!void {
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch
            @panic("Invalid number.");
        try self.emitConstant(.{ .number = value });
    }

    fn @"or"(self: *Parser, _: bool) Allocator.Error!void {
        const else_jump = try self.emitJump(.jump_if_false);
        const end_jump = try self.emitJump(.jump);

        self.patchJump(else_jump);
        // Discard the left operand when it is falsey.
        try self.emit(OpCode.pop);

        try self.parsePrecedence(.@"or");
        self.patchJump(end_jump);
    }

    fn string(self: *Parser, _: bool) Allocator.Error!void {
        // Trim double quotes.
        const str = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const obj_string = try ObjString.createByCopy(self.gc, str);
        try self.emitConstant(.{ .obj = &obj_string.obj });
    }

    fn namedVariable(self: *Parser, name: Token, can_assign: bool) Allocator.Error!void {
        var get_op: OpCode = undefined;
        var set_op: OpCode = undefined;
        var arg: u8 = undefined;
        if (self.resolveLocal(self.compiler.?, name)) |local| {
            get_op = .get_local;
            set_op = .set_local;
            arg = local;
        } else if (self.resolveUpvalue(self.compiler.?, name)) |upvalue| {
            get_op = .get_upvalue;
            set_op = .set_upvalue;
            arg = upvalue;
        } else {
            get_op = .get_global;
            set_op = .set_global;
            arg = try self.identifierConstant(name);
        }

        if (can_assign and self.match(.equal)) {
            try self.expression();
            try self.emit(.{ set_op, arg });
        } else {
            try self.emit(.{ get_op, arg });
        }
    }

    fn variable(self: *Parser, can_assign: bool) Allocator.Error!void {
        try self.namedVariable(self.previous, can_assign);
    }

    fn this(self: *Parser, _: bool) Allocator.Error!void {
        if (self.class_compiler) |_| {
            try self.variable(false);
            return;
        }

        self.errorAtPrevious(
            error.InvalidSyntax,
            "Can't use 'this' outside of a class.",
        );
    }

    fn unary(self: *Parser, _: bool) Allocator.Error!void {
        const operator_type = self.previous.token_type;

        // Compile the operand.
        try self.parsePrecedence(.unary);

        // Emit the operator instruction.
        switch (operator_type) {
            .minus => try self.emit(OpCode.negate),
            .bang => try self.emit(OpCode.not),
            else => unreachable,
        }
    }

    fn parsePrecedence(self: *Parser, precedence: Precedence) Allocator.Error!void {
        self.advance();

        const can_assign = precedence.le(.assignment);

        if (getRule(self.previous.token_type).prefix) |prefix_rule| {
            try prefix_rule(self, can_assign);
        } else {
            self.errorAtPrevious(
                error.InvalidSyntax,
                "Expect expression.",
            );
        }

        while (precedence.le(getRule(self.current.token_type).precedence)) {
            self.advance();
            const infix_rule = getRule(self.previous.token_type).infix;
            try infix_rule.?(self, can_assign);
        }

        if (can_assign and self.match(.equal)) {
            self.errorAtPrevious(
                error.InvalidSyntax,
                "Invalid assignment target.",
            );
        }
    }

    fn getRule(token_type: TokenType) ParseRule {
        return switch (token_type) {
            .left_paren => .{ .prefix = grouping, .infix = call, .precedence = .call },
            .dot => .{ .infix = dot, .precedence = .call },
            .minus => .{ .prefix = unary, .infix = binary, .precedence = .term },
            .plus => .{ .infix = binary, .precedence = .term },
            .slash, .star => .{ .infix = binary, .precedence = .factor },
            .bang => .{ .prefix = unary },
            .bang_equal, .equal_equal => .{ .infix = binary, .precedence = .equality },
            .greater, .greater_equal, .less, .less_equal => .{ .infix = binary, .precedence = .comparison },
            .identifier => .{ .prefix = variable },
            .string => .{ .prefix = string },
            .number => .{ .prefix = number },
            .@"and" => .{ .infix = @"and", .precedence = .@"and" },
            .false, .true, .nil => .{ .prefix = literal },
            .@"or" => .{ .infix = @"or", .precedence = .@"or" },
            .this => .{ .prefix = this },
            else => .{},
        };
    }

    fn expression(self: *Parser) Allocator.Error!void {
        try self.parsePrecedence(.assignment);
    }

    fn block(self: *Parser) Allocator.Error!void {
        while (!self.check(.right_brace) and !self.check(.eof)) {
            try self.declaration();
        }

        self.consume(.right_brace, "Expect '}' after block.");
    }

    fn function(self: *Parser, function_type: FunctionType) Allocator.Error!void {
        var compiler = try Compiler.init(
            self.gc,
            self.previous.lexeme,
            self.compiler,
            function_type,
        );
        self.compiler = &compiler;
        self.beginScope();

        self.consume(.left_paren, "Expect '(' after function name.");
        if (!self.check(.right_paren)) {
            while (true) {
                if (self.compiler.?.function.?.arity == 255) {
                    self.errorAtCurrent(
                        error.TooManyElements,
                        "Can't have more than 255 parameters.",
                    );
                }
                self.compiler.?.function.?.arity += 1;
                const constant = try self.parseVariable("Expect parameter name.");
                try self.defineVariable(constant);
                if (!self.match(.comma)) break;
            }
        }
        self.consume(.right_paren, "Expect ')' after parameters.");
        self.consume(.left_brace, "Expect '{' before function body.");
        try self.block();

        const obj_function = try self.endCompiler();
        const constant = try self.makeConstant(.{ .obj = &obj_function.obj });
        try self.emit(.{ OpCode.closure, constant });

        // OpCode.closure has a variably sized encoding.
        for (0..obj_function.upvalue_count) |i| {
            try self.emit(.{
                @as(u8, @intFromBool(compiler.upvalues[i].is_local)),
                compiler.upvalues[i].index,
            });
        }
    }

    fn method(self: *Parser) Allocator.Error!void {
        self.consume(.identifier, "Expect method name.");
        const constant = try self.identifierConstant(self.previous);

        if (self.previous.lexeme.len == 4 and std.mem.eql(u8, self.previous.lexeme, "init")) {
            try self.function(.initializer);
        } else {
            try self.function(.method);
        }

        try self.emit(.{ OpCode.method, constant });
    }

    fn classDeclaration(self: *Parser) Allocator.Error!void {
        self.consume(.identifier, "Expect class name.");
        const class_name = self.previous;
        const name_constant = try self.identifierConstant(class_name);
        self.declareVariable();

        try self.emit(.{ OpCode.class, name_constant });
        try self.defineVariable(name_constant);

        var target_class = ClassCompiler{
            .enclosing = self.class_compiler,
            .has_superclass = false,
        };
        self.class_compiler = &target_class;

        if (self.match(.less)) {
            self.consume(.identifier, "Expect superclass name.");
            try self.variable(false);

            if (class_name.identifierEquals(self.previous)) {
                self.errorAtPrevious(
                    error.InvalidSyntax,
                    "A class can't inherit from itself.",
                );
            }

            self.beginScope();
            self.addLocal(Token.synthetic("super"));
            try self.defineVariable(0);

            try self.namedVariable(class_name, false);
            try self.emit(OpCode.inherit);
            self.class_compiler.?.has_superclass = true;
        }

        // Push "class_name" for "OpCode.method".
        try self.namedVariable(class_name, false);

        self.consume(.left_brace, "Expect '{' before class body.");
        while (!self.check(.right_brace) and !self.check(.eof)) {
            try self.method();
        }
        self.consume(.right_brace, "Expect '}' after class body.");

        // Pop "class_name".
        try self.emit(OpCode.pop);

        if (self.class_compiler.?.has_superclass) {
            try self.endScope();
        }

        // Restore enclosing.
        self.class_compiler = self.class_compiler.?.enclosing;
    }

    fn funDeclaration(self: *Parser) Allocator.Error!void {
        const global = try self.parseVariable("Expect function name.");
        // To support recursive local functions, mark it "initalized" as soon as compile the name.
        self.markInitialized();
        try self.function(.function);
        try self.defineVariable(global);
    }

    fn varDeclaration(self: *Parser) Allocator.Error!void {
        const global = try self.parseVariable("Expect variable name.");

        if (self.match(.equal)) {
            try self.expression();
        } else {
            // Implicit initialization
            try self.emit(OpCode.nil);
        }
        self.consume(.semicolon, "Expect ';' after variable declaration.");

        try self.defineVariable(global);
    }

    fn expressionStatement(self: *Parser) Allocator.Error!void {
        try self.expression();
        self.consume(.semicolon, "Expect ';' after expression.");
        try self.emit(OpCode.pop);
    }

    fn forStatement(self: *Parser) Allocator.Error!void {
        self.beginScope();
        self.consume(.left_paren, "Expect '(' after 'for'.");
        // Initializer clause is optional.
        if (self.match(.semicolon)) {
            // No initializer.
        } else if (self.match(.@"var")) {
            try self.varDeclaration();
        } else {
            try self.expressionStatement();
        }

        var loop_start = self.currentChunk().code.items.len;
        var exit_jump: ?usize = null;
        // Condition clause is optional.
        if (!self.match(.semicolon)) {
            try self.expression();
            self.consume(.semicolon, "Expecet ';' after loop condition.");

            // Jump out of the loop if the condition is false.
            exit_jump = try self.emitJump(.jump_if_false);
            // Discard the condition when it is truthy.
            try self.emit(OpCode.pop);
        }

        // Increment clause is optional.
        if (!self.match(.right_paren)) {
            const body_jump = try self.emitJump(.jump);
            const increment_start = self.currentChunk().code.items.len;
            try self.expression();
            // Discard the increment result.
            try self.emit(OpCode.pop);
            self.consume(.right_paren, "Expect ')' after for clauses.");

            try self.emitLoop(loop_start);
            loop_start = increment_start;
            self.patchJump(body_jump);
        }

        try self.statement();
        try self.emitLoop(loop_start);

        if (exit_jump) |exit| {
            self.patchJump(exit);
            // Discard the condition when it is falsey.
            try self.emit(OpCode.pop);
        }

        try self.endScope();
    }

    fn ifStatement(self: *Parser) Allocator.Error!void {
        self.consume(.left_paren, "Expect '(' after 'if'.");
        try self.expression();
        self.consume(.right_paren, "Expect ')' after condition.");

        const then_jump = try self.emitJump(.jump_if_false);
        // Discard the condition when it is truthy.
        try self.emit(OpCode.pop);
        try self.statement();

        const else_jump = try self.emitJump(.jump);

        self.patchJump(then_jump);
        // Discard the condition when it is falsey.
        try self.emit(OpCode.pop);

        if (self.match(.@"else")) try self.statement();
        self.patchJump(else_jump);
    }

    fn printStatement(self: *Parser) Allocator.Error!void {
        try self.expression();
        self.consume(.semicolon, "Expect ';' after value.");
        try self.emit(OpCode.print);
    }

    fn returnStatement(self: *Parser) Allocator.Error!void {
        if (self.compiler.?.function_type == .script) {
            self.errorAtPrevious(
                error.InvalidSyntax,
                "Can't return from top-level code.",
            );
        }

        if (self.match(.semicolon)) {
            try self.emitReturn();
        } else {
            if (self.compiler.?.function_type == .initializer) {
                self.errorAtPrevious(
                    error.InvalidSyntax,
                    "Can't return a value from an initializer.",
                );
            }

            try self.expression();
            self.consume(.semicolon, "Expect ';' after return value.");
            try self.emit(OpCode.@"return");
        }
    }

    fn whileStatement(self: *Parser) Allocator.Error!void {
        const loop_start = self.currentChunk().code.items.len;
        self.consume(.left_paren, "Expect '(' after 'while'.");
        try self.expression();
        self.consume(.right_paren, "Expect ')' after condition.");

        const exit_jump = try self.emitJump(.jump_if_false);
        // Discard the condition when it is truthy.
        try self.emit(OpCode.pop);
        try self.statement();
        try self.emitLoop(loop_start);

        self.patchJump(exit_jump);
        // Discard the condition when it is falsey.
        try self.emit(OpCode.pop);
    }

    fn synchronize(self: *Parser) void {
        self.panic_mode = false;

        while (self.current.token_type != .eof) {
            if (self.previous.token_type == .semicolon) return;
            switch (self.current.token_type) {
                .class,
                .fun,
                .@"var",
                .@"for",
                .@"if",
                .@"while",
                .print,
                .@"return",
                => return,
                else => {}, // Do nothing.
            }

            self.advance();
        }
    }

    pub fn declaration(self: *Parser) Allocator.Error!void {
        if (self.match(.class)) {
            try self.classDeclaration();
        } else if (self.match(.fun)) {
            try self.funDeclaration();
        } else if (self.match(.@"var")) {
            try self.varDeclaration();
        } else {
            try self.statement();
        }

        if (self.panic_mode) self.synchronize();
    }

    fn statement(self: *Parser) Allocator.Error!void {
        if (self.match(.print)) {
            try self.printStatement();
        } else if (self.match(.@"for")) {
            try self.forStatement();
        } else if (self.match(.@"if")) {
            try self.ifStatement();
        } else if (self.match(.@"return")) {
            try self.returnStatement();
        } else if (self.match(.@"while")) {
            try self.whileStatement();
        } else if (self.match(.left_brace)) {
            self.beginScope();
            try self.block();
            try self.endScope();
        } else {
            try self.expressionStatement();
        }
    }

    pub fn run(self: *Parser) Error!*ObjFunction {
        var compiler = try Compiler.init(
            self.gc,
            null,
            null,
            .script,
        );
        self.compiler = &compiler;

        self.advance();
        while (!self.match(.eof)) {
            try self.declaration();
        }

        const obj_function = try self.endCompiler();
        return if (self.err) |err| err else obj_function;
    }

    fn markParserRoots(ptr: *anyopaque, gc: *GC) void {
        const self: *Parser = @ptrCast(@alignCast(ptr));

        gc.markCompilers(self.compiler);
    }
};
