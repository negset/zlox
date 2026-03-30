const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const GC = @import("memory.zig").GC;
const ObjString = @import("object.zig").ObjString;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");

pub const Error = error{
    InvalidSyntax,
    TooManyConstants,
    TooManyLocals,
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
    .left_paren = .{ .prefix = Parser.grouping },
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
    .false = .{ .prefix = Parser.literal },
    .true = .{ .prefix = Parser.literal },
    .nil = .{ .prefix = Parser.literal },
});

const Parser = struct {
    scanner: Scanner,
    compiler: *Compiler,
    gc: *GC,
    current: Token = undefined,
    previous: Token = undefined,
    compiling_chunk: *Chunk,

    pub fn init(source: []const u8, compiler: *Compiler, gc: *GC, chunk: *Chunk) Parser {
        return .{
            .scanner = .init(source),
            .compiler = compiler,
            .gc = gc,
            .compiling_chunk = chunk,
        };
    }

    fn currentChunk(self: *Parser) *Chunk {
        return self.compiling_chunk;
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

    fn emitReturn(self: *Parser, allocator: Allocator) Error!void {
        try self.emitOps(allocator, &.{.@"return"});
    }

    fn makeConstant(self: *Parser, allocator: Allocator, value: Value) Error!u8 {
        const index = try self.currentChunk().addConstant(allocator, value);
        // Make sure the chunk does not contain too many constants,
        // since OpCode.constant uses a single byte for its index operand.
        const byte = std.math.cast(u8, index) orelse {
            return self.errorAtPrevious(
                error.TooManyConstants,
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

    pub fn endCompiler(self: *Parser, allocator: Allocator) Error!void {
        try self.emitReturn(allocator);
        if (comptime debug.print_code) {
            debug.disassembleChunk(self.currentChunk(), "code");
        }
    }

    pub fn beginScope(self: *Parser) void {
        self.compiler.scope_depth += 1;
    }

    pub fn endScope(self: *Parser, allocator: Allocator) Error!void {
        const c = self.compiler;
        c.scope_depth -= 1;

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

    fn identifierEqual(a: Token, b: Token) bool {
        if (a.lexeme.len != b.lexeme.len) return false;
        return std.mem.eql(u8, a.lexeme, b.lexeme);
    }

    fn resolveLocal(self: *Parser, compiler: *Compiler, name: Token) Error!?u8 {
        for (0..compiler.local_count) |i| {
            const slot = compiler.local_count - i - 1;
            const local = &compiler.locals[slot];
            if (identifierEqual(name, local.name)) {
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
        if (self.compiler.local_count == u8_count) {
            return self.errorAtPrevious(
                error.TooManyLocals,
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

            if (identifierEqual(name, local.name)) {
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

    fn expression(self: *Parser, allocator: Allocator) Error!void {
        try self.parsePrecedence(allocator, .assignment);
    }

    fn block(self: *Parser, allocator: Allocator) Error!void {
        while (!self.check(.right_brace) and !self.check(.eof)) {
            try self.declaration(allocator);
        }

        try self.consume(.right_brace, "Expect '}' after block.");
    }

    fn varDeclaration(self: *Parser, allocator: Allocator) Error!void {
        const global = try self.parseVariable(allocator, "Expect variable name");

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
        if (try self.match(.@"var")) {
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

    fn expressionStatement(self: *Parser, allocator: Allocator) Error!void {
        try self.expression(allocator);
        try self.consume(.semicolon, "Expect ';' after expression.");
        try self.emitOps(allocator, &.{.pop});
    }

    fn statement(self: *Parser, allocator: Allocator) Error!void {
        if (try self.match(.print)) {
            try self.printStatement(allocator);
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

pub fn compile(allocator: Allocator, gc: *GC, source: []const u8, chunk: *Chunk) Error!void {
    var compiler = Compiler.init;
    var parser = Parser.init(source, &compiler, gc, chunk);

    var first_error: ?Error = null;

    try parser.advance();

    while (!try parser.match(.eof)) {
        parser.declaration(allocator) catch |err| {
            try parser.synchronize();
            if (first_error == null) first_error = err;
        };
    }

    try parser.endCompiler(allocator);

    if (first_error) |err| return err;
}

const Local = struct {
    name: Token,
    depth: ?u32,
};

const u8_count = std.math.maxInt(u8) + 1;

const Compiler = struct {
    locals: [u8_count]Local,
    local_count: u8,
    scope_depth: u32,

    pub const init = Compiler{
        .locals = undefined,
        .local_count = 0,
        .scope_depth = 0,
    };
};
