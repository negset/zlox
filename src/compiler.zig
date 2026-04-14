const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const GC = @import("memory.zig").GC;
const ObjFunction = @import("object.zig").ObjFunction;
const ObjString = @import("object.zig").ObjString;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const config = @import("config");

pub const Error = error{
    InvalidSyntax,
    TooManyElements,
} || Allocator.Error;

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

const ParseFn = *const fn (*Parser, Allocator, bool) Error!void;

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

const Parser = struct {
    scanner: Scanner,
    compiler: *Compiler,
    gc: *GC,
    current: Token = undefined,
    previous: Token = undefined,

    pub fn init(source: []const u8, compiler: *Compiler, gc: *GC) Parser {
        return .{
            .scanner = .init(source),
            .compiler = compiler,
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

    fn emitByte(self: *Parser, allocator: Allocator, byte: u8) Error!void {
        try self.currentChunk().write(allocator, byte, self.previous.line);
    }

    fn emitBytes(self: *Parser, allocator: Allocator, byte1: u8, byte2: u8) Error!void {
        try self.emitByte(allocator, byte1);
        try self.emitByte(allocator, byte2);
    }

    fn emitOps(self: *Parser, allocator: Allocator, ops: []const OpCode) Error!void {
        for (ops) |op| {
            try self.emitByte(allocator, @intFromEnum(op));
        }
    }

    fn emitLoop(self: *Parser, allocator: Allocator, loop_start: usize) Error!void {
        try self.emitOps(allocator, &.{.loop});

        // +2 to take into account the loop distance itself.
        const distance = self.currentChunk().code.items.len - loop_start + 2;
        if (distance > std.math.maxInt(u16)) {
            return self.errorAtPrevious(
                error.TooManyElements,
                "Loop body too large.",
            );
        }

        try self.emitBytes(
            allocator,
            @truncate(distance >> 8),
            @truncate(distance),
        );
    }

    fn emitJump(self: *Parser, allocator: Allocator, instruction: OpCode) Error!usize {
        try self.emitByte(allocator, @intFromEnum(instruction));
        // Emit temporary jump distance.
        try self.emitByte(allocator, 0xff);
        try self.emitByte(allocator, 0xff);
        // Return offset of jump distance.
        return self.currentChunk().code.items.len - 2;
    }

    fn emitReturn(self: *Parser, allocator: Allocator) Error!void {
        try self.emitOps(allocator, &.{.@"return"});
    }

    fn makeConstant(self: *Parser, allocator: Allocator, value: Value) Error!u8 {
        const index = try self.currentChunk().addConstant(allocator, value);
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

    fn emitConstant(self: *Parser, allocator: Allocator, value: Value) Error!void {
        try self.emitBytes(
            allocator,
            @intFromEnum(OpCode.constant),
            try self.makeConstant(allocator, value),
        );
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
        const buf = self.currentChunk().code.items[target..];
        std.mem.writeInt(u16, buf[0..2], @intCast(distance), .big);
    }

    pub fn endCompiler(self: *Parser, allocator: Allocator) Error!*const ObjFunction {
        try self.emitReturn(allocator);
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

    pub fn endScope(self: *Parser, allocator: Allocator) Error!void {
        const c = self.compiler;
        c.scope_depth -= 1;

        // Pop locals.
        while (c.local_count > 0 and c.locals[c.local_count - 1].depth.? > c.scope_depth) : (c.local_count -= 1) {
            try self.emitOps(allocator, &.{.pop});
        }
    }

    fn binary(self: *Parser, allocator: Allocator, _: bool) Error!void {
        const operator_type = self.previous.token_type;
        const rule = rules.get(operator_type);
        try self.parsePrecedence(allocator, rule.precedence.next());
        try self.emitOps(allocator, switch (operator_type) {
            .minus => &.{.subtract},
            .plus => &.{.add},
            .slash => &.{.divide},
            .star => &.{.multiply},
            .bang_equal => &.{ .equal, .not },
            .equal_equal => &.{.equal},
            .greater => &.{.greater},
            .greater_equal => &.{ .less, .not },
            .less => &.{.less},
            .less_equal => &.{ .greater, .not },
            else => unreachable,
        });
    }

    fn call(self: *Parser, allocator: Allocator, _: bool) Error!void {
        const arg_count = try self.argumentList(allocator);
        try self.emitBytes(
            allocator,
            @intFromEnum(OpCode.call),
            arg_count,
        );
    }

    fn literal(self: *Parser, allocator: Allocator, _: bool) Error!void {
        try self.emitOps(allocator, switch (self.previous.token_type) {
            .false => &.{.false},
            .nil => &.{.nil},
            .true => &.{.true},
            else => unreachable,
        });
    }

    fn grouping(self: *Parser, allocator: Allocator, _: bool) Error!void {
        try self.expression(allocator);
        try self.consume(.right_paren, "Expect ')' after expression.");
    }

    fn number(self: *Parser, allocator: Allocator, _: bool) Error!void {
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch
            @panic("Invalid number.");
        try self.emitConstant(allocator, .{ .number = value });
    }

    fn @"or"(self: *Parser, allocator: Allocator, _: bool) Error!void {
        const else_jump = try self.emitJump(allocator, .jump_if_false);
        const end_jump = try self.emitJump(allocator, .jump);

        try self.patchJump(else_jump);
        // Discard the left operand when it is falsey.
        try self.emitOps(allocator, &.{.pop});

        try self.parsePrecedence(allocator, .@"or");
        try self.patchJump(end_jump);
    }

    fn string(self: *Parser, allocator: Allocator, _: bool) Error!void {
        // Trim double quotes.
        const str = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const obj_string = try ObjString.createByCopy(allocator, self.gc, str);
        try self.emitConstant(allocator, .{ .obj = &obj_string.obj });
    }

    fn namedVariable(self: *Parser, allocator: Allocator, name: Token, can_assign: bool) Error!void {
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
            arg = try self.identifierConstant(allocator, name);
        }

        if (can_assign and try self.match(.equal)) {
            try self.expression(allocator);
            try self.emitBytes(
                allocator,
                @intFromEnum(set_op),
                arg,
            );
        } else {
            try self.emitBytes(
                allocator,
                @intFromEnum(get_op),
                arg,
            );
        }
    }

    fn variable(self: *Parser, allocator: Allocator, can_assign: bool) Error!void {
        try self.namedVariable(allocator, self.previous, can_assign);
    }

    fn unary(self: *Parser, allocator: Allocator, _: bool) Error!void {
        const operator_type = self.previous.token_type;

        // Compile the operand.
        try self.parsePrecedence(allocator, .unary);

        // Emit the operator instruction.
        switch (operator_type) {
            .minus => try self.emitOps(allocator, &.{.negate}),
            .bang => try self.emitOps(allocator, &.{.not}),
            else => unreachable,
        }
    }

    fn parsePrecedence(self: *Parser, allocator: Allocator, precedence: Precedence) Error!void {
        try self.advance();

        const can_assign = precedence.le(.assignment);

        if (rules.get(self.previous.token_type).prefix) |prefix_rule| {
            try prefix_rule(self, allocator, can_assign);
        } else {
            return self.errorAtPrevious(
                error.InvalidSyntax,
                "Expect expression.",
            );
        }

        while (precedence.le(rules.get(self.current.token_type).precedence)) {
            try self.advance();
            const infix_rule = rules.get(self.previous.token_type).infix;
            try infix_rule.?(self, allocator, can_assign);
        }

        if (can_assign and try self.match(.equal)) {
            return self.errorAtPrevious(
                error.InvalidSyntax,
                "Invalid assignment target.",
            );
        }
    }

    fn identifierConstant(self: *Parser, allocator: Allocator, name: Token) Error!u8 {
        const obj_string = try ObjString.createByCopy(allocator, self.gc, name.lexeme);
        return self.makeConstant(allocator, .{ .obj = &obj_string.obj });
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
        if (self.compiler.local_count == Compiler.u8_count) {
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

    fn parseVariable(self: *Parser, allocator: Allocator, message: []const u8) Error!u8 {
        try self.consume(.identifier, message);

        try self.declareVariable();
        // If in a local scope, return dummy index.
        if (self.compiler.scope_depth > 0) return 0;

        return self.identifierConstant(allocator, self.previous);
    }

    fn markInitialized(self: *Parser) void {
        const c = self.compiler;
        // Skip global.
        if (c.scope_depth == 0) return;
        c.locals[c.local_count - 1].depth = c.scope_depth;
    }

    fn defineVariable(self: *Parser, allocator: Allocator, global: u8) Error!void {
        // If in a local scope, use stack value as a local variable.
        if (self.compiler.scope_depth > 0) {
            self.markInitialized();
            return;
        }

        try self.emitBytes(
            allocator,
            @intFromEnum(OpCode.define_global),
            global,
        );
    }

    fn argumentList(self: *Parser, allocator: Allocator) Error!u8 {
        var arg_count: u8 = 0;
        if (!self.check(.right_paren)) {
            while (true) : (arg_count += 1) {
                try self.expression(allocator);
                if (arg_count == 255) {
                    return self.errorAtPrevious(
                        error.TooManyElements,
                        "Can't have more than 255 arguments.",
                    );
                }
                if (!try self.match(.comma)) break;
            }
        }
        try self.consume(.right_paren, "Expect ')' after arguments.");
        return arg_count;
    }

    fn @"and"(self: *Parser, allocator: Allocator, _: bool) Error!void {
        const end_jump = try self.emitJump(allocator, .jump_if_false);

        // Discard the left operand when it is truthy.
        try self.emitOps(allocator, &.{.pop});
        try self.parsePrecedence(allocator, .@"and");

        try self.patchJump(end_jump);
    }

    fn expression(self: *Parser, allocator: Allocator) Error!void {
        try self.parsePrecedence(allocator, .assignment);
    }

    fn block(self: *Parser, allocator: Allocator) Error!void {
        while (!self.check(.right_brace) and !self.check(.eof)) {
            try self.declaration(allocator);
        }

        try self.consume(.right_brace, "Expect '}' after block.");
    }

    fn function(self: *Parser, allocator: Allocator, function_type: FunctionType) Error!void {
        var compiler = try Compiler.init(
            allocator,
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
                const constant = try self.parseVariable(allocator, "Expect parameter name.");
                try self.defineVariable(allocator, constant);
                if (!try self.match(.comma)) break;
            }
        }
        try self.consume(.right_paren, "Expect ')' after parameters.");
        try self.consume(.left_brace, "Expect '{' before function body.");
        try self.block(allocator);

        const obj_function = try self.endCompiler(allocator);
        try self.emitBytes(
            allocator,
            @intFromEnum(OpCode.constant),
            try self.makeConstant(allocator, .{ .obj = &obj_function.obj }),
        );
    }

    fn funDeclaration(self: *Parser, allocator: Allocator) Error!void {
        const global = try self.parseVariable(allocator, "Expect function name.");
        // To support recursive local functions, mark it "initalized" as soon as compile the name.
        self.markInitialized();
        try self.function(allocator, .function);
        try self.defineVariable(allocator, global);
    }

    fn varDeclaration(self: *Parser, allocator: Allocator) Error!void {
        const global = try self.parseVariable(allocator, "Expect variable name.");

        if (try self.match(.equal)) {
            try self.expression(allocator);
        } else {
            // Implicit initialization
            try self.emitOps(allocator, &.{.nil});
        }
        try self.consume(.semicolon, "Expect ';' after variable declaration.");

        try self.defineVariable(allocator, global);
    }

    pub fn declaration(self: *Parser, allocator: Allocator) Error!void {
        if (try self.match(.fun)) {
            try self.funDeclaration(allocator);
        } else if (try self.match(.@"var")) {
            try self.varDeclaration(allocator);
        } else {
            try self.statement(allocator);
        }
    }

    fn printStatement(self: *Parser, allocator: Allocator) Error!void {
        try self.expression(allocator);
        try self.consume(.semicolon, "Expect ';' after value.");
        try self.emitOps(allocator, &.{.print});
    }

    fn whileStatement(self: *Parser, allocator: Allocator) Error!void {
        const loop_start = self.currentChunk().code.items.len;
        try self.consume(.left_paren, "Expect '(' after 'while'.");
        try self.expression(allocator);
        try self.consume(.right_paren, "Expect ')' after condition.");

        const exit_jump = try self.emitJump(allocator, .jump_if_false);
        // Discard the condition when it is truthy.
        try self.emitOps(allocator, &.{.pop});
        try self.statement(allocator);
        try self.emitLoop(allocator, loop_start);

        try self.patchJump(exit_jump);
        // Discard the condition when it is falsey.
        try self.emitOps(allocator, &.{.pop});
    }

    fn expressionStatement(self: *Parser, allocator: Allocator) Error!void {
        try self.expression(allocator);
        try self.consume(.semicolon, "Expect ';' after expression.");
        try self.emitOps(allocator, &.{.pop});
    }

    fn forStatement(self: *Parser, allocator: Allocator) Error!void {
        self.beginScope();
        try self.consume(.left_paren, "Expect '(' after 'for'.");
        // Initializer clause is optional.
        if (try self.match(.semicolon)) {
            // No initializer.
        } else if (try self.match(.@"var")) {
            try self.varDeclaration(allocator);
        } else {
            try self.expressionStatement(allocator);
        }

        var loop_start = self.currentChunk().code.items.len;
        var exit_jump: ?usize = null;
        // Condition clause is optional.
        if (!try self.match(.semicolon)) {
            try self.expression(allocator);
            try self.consume(.semicolon, "Expecet ';' after loop condition.");

            // Jump out of the loop if the condition is false.
            exit_jump = try self.emitJump(allocator, .jump_if_false);
            // Discard the condition when it is truthy.
            try self.emitOps(allocator, &.{.pop});
        }

        // Increment clause is optional.
        if (!try self.match(.right_paren)) {
            const body_jump = try self.emitJump(allocator, .jump);
            const increment_start = self.currentChunk().code.items.len;
            try self.expression(allocator);
            // Discard the increment result.
            try self.emitOps(allocator, &.{.pop});
            try self.consume(.right_paren, "Expect ')' after for clauses.");

            try self.emitLoop(allocator, loop_start);
            loop_start = increment_start;
            try self.patchJump(body_jump);
        }

        try self.statement(allocator);
        try self.emitLoop(allocator, loop_start);

        if (exit_jump) |_| {
            try self.patchJump(exit_jump.?);
            // Discard the condition when it is falsey.
            try self.emitOps(allocator, &.{.pop});
        }

        try self.endScope(allocator);
    }

    fn ifStatement(self: *Parser, allocator: Allocator) Error!void {
        try self.consume(.left_paren, "Expect '(' after 'if'.");
        try self.expression(allocator);
        try self.consume(.right_paren, "Expect ')' after condition.");

        const then_jump = try self.emitJump(allocator, .jump_if_false);
        // Discard the condition when it is truthy.
        try self.emitOps(allocator, &.{.pop});
        try self.statement(allocator);

        const else_jump = try self.emitJump(allocator, .jump);

        try self.patchJump(then_jump);
        // Discard the condition when it is falsey.
        try self.emitOps(allocator, &.{.pop});

        if (try self.match(.@"else")) try self.statement(allocator);
        try self.patchJump(else_jump);
    }

    fn statement(self: *Parser, allocator: Allocator) Error!void {
        if (try self.match(.print)) {
            try self.printStatement(allocator);
        } else if (try self.match(.@"for")) {
            try self.forStatement(allocator);
        } else if (try self.match(.@"if")) {
            try self.ifStatement(allocator);
        } else if (try self.match(.@"while")) {
            try self.whileStatement(allocator);
        } else if (try self.match(.left_brace)) {
            self.beginScope();
            try self.block(allocator);
            try self.endScope(allocator);
        } else {
            try self.expressionStatement(allocator);
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
};

const Local = struct {
    name: Token,
    // Null if it is uninitialized.
    depth: ?u32,
};

const FunctionType = enum {
    function,
    script,
};

pub const Compiler = struct {
    enclosing: ?*Compiler,
    function: ?*ObjFunction,
    function_type: FunctionType,

    locals: [u8_count]Local,
    local_count: u8,
    scope_depth: u32,

    pub const u8_count = std.math.maxInt(u8) + 1;

    pub fn init(
        allocator: Allocator,
        gc: *GC,
        name: ?[]const u8,
        enclosing: ?*Compiler,
        function_type: FunctionType,
    ) Allocator.Error!@This() {
        var new = Compiler{
            .enclosing = enclosing,
            // Set null beforehand to prevent GC from running on
            // uninitialized "function" when calling ObjFunction.create.
            .function = null,
            .function_type = function_type,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
        };
        new.function = try ObjFunction.create(allocator, gc);
        if (function_type != .script) {
            new.function.?.name = try ObjString.createByCopy(allocator, gc, name.?);
        }

        const local = &new.locals[new.local_count];
        new.local_count += 1;
        local.depth = 0;
        local.name.lexeme = "";

        return new;
    }
};

pub fn compile(allocator: Allocator, gc: *GC, source: []const u8) Error!*const ObjFunction {
    var compiler = try Compiler.init(
        allocator,
        gc,
        null,
        null,
        .script,
    );
    var parser = Parser.init(source, &compiler, gc);

    var first_error: ?Error = null;

    try parser.advance();

    while (!try parser.match(.eof)) {
        parser.declaration(allocator) catch |err| {
            try parser.synchronize();
            if (first_error == null) first_error = err;
        };
    }

    const function = try parser.endCompiler(allocator);

    return if (first_error) |err| err else function;
}
