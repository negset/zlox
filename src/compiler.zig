const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const ObjString = @import("object.zig").ObjString;
const OpCode = @import("chunk.zig").OpCode;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");

pub const Error = error{ InvalidSyntax, TooManyConstants } || Allocator.Error;

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

const ParseFn = *const fn (*Parser, Allocator) Error!void;

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
    .string = .{ .prefix = Parser.string },
    .number = .{ .prefix = Parser.number },
    .false = .{ .prefix = Parser.literal },
    .true = .{ .prefix = Parser.literal },
    .nil = .{ .prefix = Parser.literal },
});

const Parser = struct {
    scanner: *Scanner,
    compiling_chunk: *Chunk,
    current: Token = undefined,
    previous: Token = undefined,

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

            return self.errorAtCurrent(Error.InvalidSyntax, self.current.lexeme);
        }
    }

    pub fn consume(self: *Parser, token_type: TokenType, message: []const u8) Error!void {
        if (self.current.token_type == token_type) {
            try self.advance();
            return;
        }

        return self.errorAtCurrent(Error.InvalidSyntax, message);
    }

    fn emitByte(self: *Parser, allocator: Allocator, byte: u8) Error!void {
        try self.compiling_chunk.write(allocator, byte, self.previous.line);
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
        const index = try self.compiling_chunk.addConstant(allocator, value);
        // Make sure the chunk does not contain too many constants,
        // since OpCode.constant uses a single byte for its index operand.
        const byte = std.math.cast(u8, index) orelse {
            return self.errorAtPrevious(Error.TooManyConstants, "Too many constants in one chunk.");
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
            debug.disassembleChunk(self.compiling_chunk, "code");
        }
    }

    fn binary(self: *Parser, allocator: Allocator) Error!void {
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

    fn literal(self: *Parser, allocator: Allocator) Error!void {
        try self.emitOps(allocator, switch (self.previous.token_type) {
            .false => &.{.false},
            .nil => &.{.nil},
            .true => &.{.true},
            else => unreachable,
        });
    }

    fn grouping(self: *Parser, allocator: Allocator) Error!void {
        try self.expression(allocator);
        try self.consume(.right_paren, "Expect ')' after expression.");
    }

    fn number(self: *Parser, allocator: Allocator) Error!void {
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch
            @panic("Invalid number.");
        try self.emitConstant(allocator, .{ .number = value });
    }

    fn string(self: *Parser, allocator: Allocator) Error!void {
        // Trim double quotes.
        const s = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const obj_string = try ObjString.createByCopy(allocator, s);
        try self.emitConstant(allocator, .{ .obj = &obj_string.obj });
    }

    fn unary(self: *Parser, allocator: Allocator) Error!void {
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
        if (rules.get(self.previous.token_type).prefix) |prefix_rule| {
            try prefix_rule(self, allocator);
        } else {
            return self.errorAtPrevious(Error.InvalidSyntax, "Expect expression.");
        }

        while (precedence.le(rules.get(self.current.token_type).precedence)) {
            try self.advance();
            const infix_rule = rules.get(self.previous.token_type).infix;
            try infix_rule.?(self, allocator);
        }
    }

    pub fn expression(self: *Parser, allocator: Allocator) Error!void {
        try self.parsePrecedence(allocator, .assignment);
    }
};

pub fn compile(allocator: Allocator, source: []const u8, chunk: *Chunk) Error!void {
    var scanner = Scanner{ .source = source };
    var parser = Parser{
        .scanner = &scanner,
        .compiling_chunk = chunk,
    };
    try parser.advance();
    try parser.expression(allocator);
    try parser.consume(.eof, "Expect end of expression.");
    try parser.endCompiler(allocator);
}
