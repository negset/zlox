const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Compiler = @import("compiler.zig").Compiler;
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

const ParseFn = *const fn (*Parser, Allocator, bool) Parser.Error!void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence = .none,
};

const rules = std.EnumArray(TokenType, ParseRule).initDefault(.{}, .{
    .left_paren = .{ .prefix = Parser.grouping, .infix = Parser.call, .precedence = .call },
    .minus = .{ .prefix = Parser.unary, .infix = Parser.binary, .precedence = .term },
    .plus = .{ .infix = Parser.binary, .precedence = .term },
    .slash = .{ .infix = Parser.binary, .precedence = .factor },
    .star = .{ .infix = Parser.binary, .precedence = .factor },
    .bang = .{ .prefix = Parser.unary },
    .bang_equal = .{ .infix = Parser.binary, .precedence = .equality },
    .equal_equal = .{ .infix = Parser.binary, .precedence = .equality },
    .greater = .{ .infix = Parser.binary, .precedence = .comparison },
    .greater_equal = .{ .infix = Parser.binary, .precedence = .comparison },
    .less = .{ .infix = Parser.binary, .precedence = .comparison },
    .less_equal = .{ .infix = Parser.binary, .precedence = .comparison },
    .identifier = .{ .prefix = Parser.variable },
    .string = .{ .prefix = Parser.string },
    .number = .{ .prefix = Parser.number },
    .@"and" = .{ .infix = Parser.@"and", .precedence = .@"and" },
    .false = .{ .prefix = Parser.literal },
    .true = .{ .prefix = Parser.literal },
    .nil = .{ .prefix = Parser.literal },
    .@"or" = .{ .infix = Parser.@"or", .precedence = .@"or" },
});

pub const Parser = struct {
    scanner: Scanner,
    compiler: *Compiler = undefined,
    gc: *GC,
    current: Token = undefined,
    previous: Token = undefined,

    pub const Error = error{
        InvalidSyntax,
        TooManyElements,
    } || Allocator.Error;

    pub fn init(source: []const u8, gc: *GC) Parser {
        return .{
            .scanner = .init(source),
            .gc = gc,
        };
    }

    fn currentChunk(self: *Parser) *Chunk {
        return &self.compiler.function.?.chunk;
    }

    fn errorAt(token: Token, err: Error, message: []const u8) Error {
        std.debug.print("[line {d}] {s} (comptime)", .{ token.line, @errorName(err) });

        switch (token.token_type) {
            .eof => std.debug.print(" at end", .{}),
            .@"error" => {}, // Nothing.
            else => std.debug.print(" at '{s}'", .{token.lexeme}),
        }

        std.debug.print(": {s}\n", .{message});
        return err;
    }

    fn errorAtPrevious(self: *Parser, err: Error, message: []const u8) Error {
        return errorAt(self.previous, err, message);
    }

    fn errorAtCurrent(self: *Parser, err: Error, message: []const u8) Error {
        return errorAt(self.current, err, message);
    }

    pub fn advance(self: *Parser) Error!void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scanToken();
            if (self.current.token_type != .@"error") break;

            return self.errorAtCurrent(error.InvalidSyntax, self.current.lexeme);
        }
    }

    pub fn consume(self: *Parser, token_type: TokenType, message: []const u8) Error!void {
        if (self.current.token_type == token_type) {
            try self.advance();
            return;
        }

        return self.errorAtCurrent(error.InvalidSyntax, message);
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        return self.current.token_type == token_type;
    }

    pub fn match(self: *Parser, token_type: TokenType) Error!bool {
        if (!self.check(token_type)) return false;
        try self.advance();
        return true;
    }

    fn emit(self: *Parser, gpa: Allocator, data: anytype) Error!void {
        const T = @TypeOf(data);
        switch (@typeInfo(T)) {
            .int => {
                if (T != u8) @compileError("Incompatible int type to emit: " ++ @typeName(T));
                try self.currentChunk().write(gpa, @intCast(data), self.previous.line);
            },
            .@"enum" => {
                if (T != OpCode) @compileError("Incompatible enum type to emit: " ++ @typeName(T));
                try self.currentChunk().write(gpa, @intFromEnum(data), self.previous.line);
            },
            .@"struct" => |s| {
                inline for (s.fields) |field| {
                    try self.emit(gpa, @field(data, field.name));
                }
            },
            else => @compileError("Incompatible type to emit: " ++ @typeName(T)),
        }
    }

    fn emitLoop(self: *Parser, gpa: Allocator, loop_start: usize) Error!void {
        try self.emit(gpa, OpCode.loop);

        // +2 to take into account the loop distance itself.
        const distance = self.currentChunk().code.items.len - loop_start + 2;
        if (distance > std.math.maxInt(u16)) {
            return self.errorAtPrevious(
                error.TooManyElements,
                "Loop body too large.",
            );
        }

        try self.emit(gpa, .{ @as(u8, @truncate(distance >> 8)), @as(u8, @truncate(distance)) });
    }

    fn emitJump(self: *Parser, gpa: Allocator, instruction: OpCode) Error!usize {
        try self.emit(gpa, instruction);
        // Emit temporary jump distance.
        try self.emit(gpa, @as(u8, 0xff));
        try self.emit(gpa, @as(u8, 0xff));
        // Return offset of jump distance.
        return self.currentChunk().code.items.len - 2;
    }

    fn emitReturn(self: *Parser, gpa: Allocator) Error!void {
        try self.emit(gpa, .{ OpCode.nil, OpCode.@"return" });
    }

    fn makeConstant(self: *Parser, gpa: Allocator, value: Value) Error!u8 {
        const index = try self.currentChunk().addConstant(gpa, value);
        // Make sure the chunk does not contain too many constants,
        // since OpCode.constant uses a single byte for its index operand.
        const byte = std.math.cast(u8, index) orelse {
            return self.errorAtPrevious(
                error.TooManyElements,
                "Too many constants in one chunk.",
            );
        };
        return byte;
    }

    fn emitConstant(self: *Parser, gpa: Allocator, value: Value) Error!void {
        const constant = try self.makeConstant(gpa, value);
        try self.emit(gpa, .{ OpCode.constant, constant });
    }

    fn patchJump(self: *Parser, target: usize) Error!void {
        // -2 to take into account the jump distance itself.
        const distance = self.currentChunk().code.items.len - target - 2;

        if (distance > std.math.maxInt(u16)) {
            return self.errorAtPrevious(
                error.TooManyElements,
                "Too much code to jump over.",
            );
        }

        // Patch jump distance into previously emitted one.
        const buf = self.currentChunk().code.items[target..][0..2];
        std.mem.writeInt(u16, buf, @intCast(distance), .big);
    }

    pub fn endCompiler(self: *Parser, gpa: Allocator) Error!*const ObjFunction {
        try self.emitReturn(gpa);
        const obj_function = self.compiler.function.?;

        if (comptime config.print_code) {
            const name = if (obj_function.name) |n| n.string else "<script>";
            debug.disassembleChunk(self.currentChunk(), name);
        }

        if (self.compiler.enclosing) |enclosing| {
            self.compiler = enclosing;
        }
        return obj_function;
    }

    pub fn beginScope(self: *Parser) void {
        self.compiler.scope_depth += 1;
    }

    pub fn endScope(self: *Parser, gpa: Allocator) Error!void {
        const c = self.compiler;
        c.scope_depth -= 1;

        // Pop locals.
        while (c.local_count > 0 and c.locals[c.local_count - 1].depth.? > c.scope_depth) : (c.local_count -= 1) {
            try self.emit(gpa, OpCode.pop);
        }
    }

    fn binary(self: *Parser, gpa: Allocator, _: bool) Error!void {
        const operator_type = self.previous.token_type;
        const rule = rules.get(operator_type);
        try self.parsePrecedence(gpa, rule.precedence.next());
        switch (operator_type) {
            .minus => try self.emit(gpa, OpCode.subtract),
            .plus => try self.emit(gpa, OpCode.add),
            .slash => try self.emit(gpa, OpCode.divide),
            .star => try self.emit(gpa, OpCode.multiply),
            .bang_equal => try self.emit(gpa, .{ OpCode.equal, OpCode.not }),
            .equal_equal => try self.emit(gpa, OpCode.equal),
            .greater => try self.emit(gpa, OpCode.greater),
            .greater_equal => try self.emit(gpa, .{ OpCode.less, OpCode.not }),
            .less => try self.emit(gpa, OpCode.less),
            .less_equal => try self.emit(gpa, .{ OpCode.greater, OpCode.not }),
            else => unreachable,
        }
    }

    fn call(self: *Parser, gpa: Allocator, _: bool) Error!void {
        const arg_count = try self.argumentList(gpa);
        try self.emit(gpa, .{ OpCode.call, arg_count });
    }

    fn literal(self: *Parser, gpa: Allocator, _: bool) Error!void {
        switch (self.previous.token_type) {
            .false => try self.emit(gpa, OpCode.false),
            .nil => try self.emit(gpa, OpCode.nil),
            .true => try self.emit(gpa, OpCode.true),
            else => unreachable,
        }
    }

    fn grouping(self: *Parser, gpa: Allocator, _: bool) Error!void {
        try self.expression(gpa);
        try self.consume(.right_paren, "Expect ')' after expression.");
    }

    fn number(self: *Parser, gpa: Allocator, _: bool) Error!void {
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch
            @panic("Invalid number.");
        try self.emitConstant(gpa, .{ .number = value });
    }

    fn @"or"(self: *Parser, gpa: Allocator, _: bool) Error!void {
        const else_jump = try self.emitJump(gpa, .jump_if_false);
        const end_jump = try self.emitJump(gpa, .jump);

        try self.patchJump(else_jump);
        // Discard the left operand when it is falsey.
        try self.emit(gpa, OpCode.pop);

        try self.parsePrecedence(gpa, .@"or");
        try self.patchJump(end_jump);
    }

    fn string(self: *Parser, gpa: Allocator, _: bool) Error!void {
        // Trim double quotes.
        const str = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const obj_string = try ObjString.createByCopy(gpa, self.gc, str);
        try self.emitConstant(gpa, .{ .obj = &obj_string.obj });
    }

    fn namedVariable(self: *Parser, gpa: Allocator, name: Token, can_assign: bool) Error!void {
        var get_op: OpCode = undefined;
        var set_op: OpCode = undefined;
        var arg: u8 = undefined;
        if (try self.resolveLocal(self.compiler, name)) |local| {
            get_op = .get_local;
            set_op = .set_local;
            arg = local;
        } else {
            get_op = .get_global;
            set_op = .set_global;
            arg = try self.identifierConstant(gpa, name);
        }

        if (can_assign and try self.match(.equal)) {
            try self.expression(gpa);
            try self.emit(gpa, .{ set_op, arg });
        } else {
            try self.emit(gpa, .{ get_op, arg });
        }
    }

    fn variable(self: *Parser, gpa: Allocator, can_assign: bool) Error!void {
        try self.namedVariable(gpa, self.previous, can_assign);
    }

    fn unary(self: *Parser, gpa: Allocator, _: bool) Error!void {
        const operator_type = self.previous.token_type;

        // Compile the operand.
        try self.parsePrecedence(gpa, .unary);

        // Emit the operator instruction.
        switch (operator_type) {
            .minus => try self.emit(gpa, OpCode.negate),
            .bang => try self.emit(gpa, OpCode.not),
            else => unreachable,
        }
    }

    fn parsePrecedence(self: *Parser, gpa: Allocator, precedence: Precedence) Error!void {
        try self.advance();

        const can_assign = precedence.le(.assignment);

        if (rules.get(self.previous.token_type).prefix) |prefix_rule| {
            try prefix_rule(self, gpa, can_assign);
        } else {
            return self.errorAtPrevious(
                error.InvalidSyntax,
                "Expect expression.",
            );
        }

        while (precedence.le(rules.get(self.current.token_type).precedence)) {
            try self.advance();
            const infix_rule = rules.get(self.previous.token_type).infix;
            try infix_rule.?(self, gpa, can_assign);
        }

        if (can_assign and try self.match(.equal)) {
            return self.errorAtPrevious(
                error.InvalidSyntax,
                "Invalid assignment target.",
            );
        }
    }

    fn identifierConstant(self: *Parser, gpa: Allocator, name: Token) Error!u8 {
        const obj_string = try ObjString.createByCopy(gpa, self.gc, name.lexeme);
        return self.makeConstant(gpa, .{ .obj = &obj_string.obj });
    }

    fn resolveLocal(self: *Parser, compiler: *Compiler, name: Token) Error!?u8 {
        for (0..compiler.local_count) |i| {
            const slot = compiler.local_count - i - 1;
            const local = &compiler.locals[slot];
            if (name.identifierEquals(local.name)) {
                if (local.depth == null) {
                    return self.errorAtPrevious(
                        error.InvalidSyntax,
                        "Can't read local variable in its own initializer.",
                    );
                }
                return @intCast(slot);
            }
        }

        return null;
    }

    fn addLocal(self: *Parser, name: Token) Error!void {
        if (self.compiler.local_count == Compiler.locals_max) {
            return self.errorAtPrevious(
                error.TooManyElements,
                "Too many local variables in function.",
            );
        }

        defer self.compiler.local_count += 1;
        const local = &self.compiler.locals[self.compiler.local_count];
        local.name = name;
        local.depth = null;
    }

    fn declareVariable(self: *Parser) Error!void {
        // Skip global variable.
        if (self.compiler.scope_depth == 0) return;

        const name = self.previous;
        for (0..self.compiler.local_count) |i| {
            const local = &self.compiler.locals[self.compiler.local_count - i - 1];
            if (local.depth) |depth| {
                if (depth < self.compiler.scope_depth) break;
            }

            if (name.identifierEquals(local.name)) {
                return self.errorAtPrevious(
                    error.InvalidSyntax,
                    "Already a variable with this name in this scope.",
                );
            }
        }

        try self.addLocal(name);
    }

    fn parseVariable(self: *Parser, gpa: Allocator, message: []const u8) Error!u8 {
        try self.consume(.identifier, message);

        try self.declareVariable();
        // If in a local scope, return dummy index.
        if (self.compiler.scope_depth > 0) return 0;

        return self.identifierConstant(gpa, self.previous);
    }

    fn markInitialized(self: *Parser) void {
        const c = self.compiler;
        // Skip global.
        if (c.scope_depth == 0) return;
        c.locals[c.local_count - 1].depth = c.scope_depth;
    }

    fn defineVariable(self: *Parser, gpa: Allocator, global: u8) Error!void {
        // If in a local scope, use stack value as a local variable.
        if (self.compiler.scope_depth > 0) {
            self.markInitialized();
            return;
        }

        try self.emit(gpa, .{ OpCode.define_global, global });
    }

    fn argumentList(self: *Parser, gpa: Allocator) Error!u8 {
        var arg_count: u8 = 0;
        if (!self.check(.right_paren)) {
            while (true) {
                try self.expression(gpa);
                if (arg_count == 255) {
                    return self.errorAtPrevious(
                        error.TooManyElements,
                        "Can't have more than 255 arguments.",
                    );
                }
                arg_count += 1;
                if (!try self.match(.comma)) break;
            }
        }
        try self.consume(.right_paren, "Expect ')' after arguments.");
        return arg_count;
    }

    fn @"and"(self: *Parser, gpa: Allocator, _: bool) Error!void {
        const end_jump = try self.emitJump(gpa, .jump_if_false);

        // Discard the left operand when it is truthy.
        try self.emit(gpa, OpCode.pop);
        try self.parsePrecedence(gpa, .@"and");

        try self.patchJump(end_jump);
    }

    fn expression(self: *Parser, gpa: Allocator) Error!void {
        try self.parsePrecedence(gpa, .assignment);
    }

    fn block(self: *Parser, gpa: Allocator) Error!void {
        while (!self.check(.right_brace) and !self.check(.eof)) {
            try self.declaration(gpa);
        }

        try self.consume(.right_brace, "Expect '}' after block.");
    }

    fn function(self: *Parser, gpa: Allocator, function_type: FunctionType) Error!void {
        var compiler = try Compiler.init(
            gpa,
            self.gc,
            self.previous.lexeme,
            self.compiler,
            function_type,
        );
        self.compiler = &compiler;
        self.beginScope();

        try self.consume(.left_paren, "Expect '(' after function name.");
        if (!self.check(.right_paren)) {
            while (true) {
                if (self.compiler.function.?.arity == 255) {
                    return self.errorAtCurrent(
                        error.TooManyElements,
                        "Can't have more than 255 parameters.",
                    );
                }
                self.compiler.function.?.arity += 1;
                const constant = try self.parseVariable(gpa, "Expect parameter name.");
                try self.defineVariable(gpa, constant);
                if (!try self.match(.comma)) break;
            }
        }
        try self.consume(.right_paren, "Expect ')' after parameters.");
        try self.consume(.left_brace, "Expect '{' before function body.");
        try self.block(gpa);

        const obj_function = try self.endCompiler(gpa);
        const constant = try self.makeConstant(gpa, .{ .obj = &obj_function.obj });
        try self.emit(gpa, .{ OpCode.constant, constant });
    }

    fn funDeclaration(self: *Parser, gpa: Allocator) Error!void {
        const global = try self.parseVariable(gpa, "Expect function name.");
        // To support recursive local functions, mark it "initalized" as soon as compile the name.
        self.markInitialized();
        try self.function(gpa, .function);
        try self.defineVariable(gpa, global);
    }

    fn varDeclaration(self: *Parser, gpa: Allocator) Error!void {
        const global = try self.parseVariable(gpa, "Expect variable name.");

        if (try self.match(.equal)) {
            try self.expression(gpa);
        } else {
            // Implicit initialization
            try self.emit(gpa, OpCode.nil);
        }
        try self.consume(.semicolon, "Expect ';' after variable declaration.");

        try self.defineVariable(gpa, global);
    }

    pub fn declaration(self: *Parser, gpa: Allocator) Error!void {
        if (try self.match(.fun)) {
            try self.funDeclaration(gpa);
        } else if (try self.match(.@"var")) {
            try self.varDeclaration(gpa);
        } else {
            try self.statement(gpa);
        }
    }

    fn printStatement(self: *Parser, gpa: Allocator) Error!void {
        try self.expression(gpa);
        try self.consume(.semicolon, "Expect ';' after value.");
        try self.emit(gpa, OpCode.print);
    }

    fn returnStatement(self: *Parser, gpa: Allocator) Error!void {
        if (self.compiler.function_type == .script) {
            return self.errorAtPrevious(
                error.InvalidSyntax,
                "Can't return from top-level code.",
            );
        }

        if (try self.match(.semicolon)) {
            try self.emitReturn(gpa);
        } else {
            try self.expression(gpa);
            try self.consume(.semicolon, "Expect ';' after return value.");
            try self.emit(gpa, OpCode.@"return");
        }
    }

    fn whileStatement(self: *Parser, gpa: Allocator) Error!void {
        const loop_start = self.currentChunk().code.items.len;
        try self.consume(.left_paren, "Expect '(' after 'while'.");
        try self.expression(gpa);
        try self.consume(.right_paren, "Expect ')' after condition.");

        const exit_jump = try self.emitJump(gpa, .jump_if_false);
        // Discard the condition when it is truthy.
        try self.emit(gpa, OpCode.pop);
        try self.statement(gpa);
        try self.emitLoop(gpa, loop_start);

        try self.patchJump(exit_jump);
        // Discard the condition when it is falsey.
        try self.emit(gpa, OpCode.pop);
    }

    fn expressionStatement(self: *Parser, gpa: Allocator) Error!void {
        try self.expression(gpa);
        try self.consume(.semicolon, "Expect ';' after expression.");
        try self.emit(gpa, OpCode.pop);
    }

    fn forStatement(self: *Parser, gpa: Allocator) Error!void {
        self.beginScope();
        try self.consume(.left_paren, "Expect '(' after 'for'.");
        // Initializer clause is optional.
        if (try self.match(.semicolon)) {
            // No initializer.
        } else if (try self.match(.@"var")) {
            try self.varDeclaration(gpa);
        } else {
            try self.expressionStatement(gpa);
        }

        var loop_start = self.currentChunk().code.items.len;
        var exit_jump: ?usize = null;
        // Condition clause is optional.
        if (!try self.match(.semicolon)) {
            try self.expression(gpa);
            try self.consume(.semicolon, "Expecet ';' after loop condition.");

            // Jump out of the loop if the condition is false.
            exit_jump = try self.emitJump(gpa, .jump_if_false);
            // Discard the condition when it is truthy.
            try self.emit(gpa, OpCode.pop);
        }

        // Increment clause is optional.
        if (!try self.match(.right_paren)) {
            const body_jump = try self.emitJump(gpa, .jump);
            const increment_start = self.currentChunk().code.items.len;
            try self.expression(gpa);
            // Discard the increment result.
            try self.emit(gpa, OpCode.pop);
            try self.consume(.right_paren, "Expect ')' after for clauses.");

            try self.emitLoop(gpa, loop_start);
            loop_start = increment_start;
            try self.patchJump(body_jump);
        }

        try self.statement(gpa);
        try self.emitLoop(gpa, loop_start);

        if (exit_jump) |_| {
            try self.patchJump(exit_jump.?);
            // Discard the condition when it is falsey.
            try self.emit(gpa, OpCode.pop);
        }

        try self.endScope(gpa);
    }

    fn ifStatement(self: *Parser, gpa: Allocator) Error!void {
        try self.consume(.left_paren, "Expect '(' after 'if'.");
        try self.expression(gpa);
        try self.consume(.right_paren, "Expect ')' after condition.");

        const then_jump = try self.emitJump(gpa, .jump_if_false);
        // Discard the condition when it is truthy.
        try self.emit(gpa, OpCode.pop);
        try self.statement(gpa);

        const else_jump = try self.emitJump(gpa, .jump);

        try self.patchJump(then_jump);
        // Discard the condition when it is falsey.
        try self.emit(gpa, OpCode.pop);

        if (try self.match(.@"else")) try self.statement(gpa);
        try self.patchJump(else_jump);
    }

    fn statement(self: *Parser, gpa: Allocator) Error!void {
        if (try self.match(.print)) {
            try self.printStatement(gpa);
        } else if (try self.match(.@"for")) {
            try self.forStatement(gpa);
        } else if (try self.match(.@"if")) {
            try self.ifStatement(gpa);
        } else if (try self.match(.@"return")) {
            try self.returnStatement(gpa);
        } else if (try self.match(.@"while")) {
            try self.whileStatement(gpa);
        } else if (try self.match(.left_brace)) {
            self.beginScope();
            try self.block(gpa);
            try self.endScope(gpa);
        } else {
            try self.expressionStatement(gpa);
        }
    }

    fn synchronize(self: *Parser) Error!void {
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

            try self.advance();
        }
    }

    pub fn run(self: *Parser, gpa: Allocator) Error!*const ObjFunction {
        var compiler = try Compiler.init(
            gpa,
            self.gc,
            null,
            null,
            .script,
        );
        self.compiler = &compiler;

        var first_error: ?Error = null;
        try self.advance();
        while (!try self.match(.eof)) {
            self.declaration(gpa) catch |err| {
                try self.synchronize();
                if (first_error == null) first_error = err;
            };
        }
        return if (first_error) |err| err else try self.endCompiler(gpa);
    }
};
