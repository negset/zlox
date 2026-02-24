const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");

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

const ParseFn = *const fn (*Parser, Allocator) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

const Parser = struct {
    scanner: *Scanner,
    compiling_chunk: *Chunk,
    current: Token = undefined,
    previous: Token = undefined,

    fn errorAt(token: Token, message: []const u8) !void {
        std.debug.print("[line {d}] Error", .{token.line});

        switch (token.token_type) {
            .eof => std.debug.print(" at end", .{}),
            .@"error" => {}, // Nothing.
            else => std.debug.print(" at '{s}'", .{token.lexeme}),
        }

        std.debug.print(": {s}\n", .{message});
        return error.CompileError;
    }

    fn errorAtPrevious(self: *Parser, message: []const u8) !void {
        try errorAt(self.previous, message);
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) !void {
        try errorAt(self.current, message);
    }

    pub fn advance(self: *Parser) !void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scanToken();
            if (self.current.token_type != .@"error") break;

            try self.errorAtCurrent(self.current.lexeme);
        }
    }

    pub fn consume(self: *Parser, token_type: TokenType, message: []const u8) !void {
        if (self.current.token_type == token_type) {
            try self.advance();
            return;
        }

        try self.errorAtCurrent(message);
    }

    fn emitByte(self: *Parser, allocator: Allocator, byte: u8) !void {
        try self.compiling_chunk.write(allocator, byte, self.previous.line);
    }

    fn emitBytes(self: *Parser, allocator: Allocator, byte1: u8, byte2: u8) !void {
        try self.emitByte(allocator, byte1);
        try self.emitByte(allocator, byte2);
    }

    fn emitReturn(self: *Parser, allocator: Allocator) !void {
        try self.emitByte(allocator, @intFromEnum(OpCode.@"return"));
    }

    fn makeConstant(self: *Parser, allocator: Allocator, value: Value) !u8 {
        const index = try self.compiling_chunk.addConstant(allocator, value);
        // Make sure the chunk does not contain too many constants,
        // since OpCode.constant uses a single byte for its index operand.
        const byte = std.math.cast(u8, index) orelse {
            try self.errorAtPrevious("Too many constants in one chunk.");
            return 0;
        };
        return byte;
    }

    fn emitConstant(self: *Parser, allocator: Allocator, value: Value) !void {
        try self.emitBytes(
            allocator,
            @intFromEnum(OpCode.constant),
            try self.makeConstant(allocator, value),
        );
    }

    pub fn endCompiler(self: *Parser, allocator: Allocator) !void {
        try self.emitReturn(allocator);
        if (debug.print_code) {
            debug.disassembleChunk(self.compiling_chunk, "code");
        }
    }

    fn binary(self: *Parser, allocator: Allocator) !void {
        const operator_type = self.previous.token_type;
        const rule = getRule(operator_type);
        try self.parsePrecedence(allocator, rule.precedence.next());

        const op: OpCode =
            switch (operator_type) {
                .plus => .add,
                .minus => .subtract,
                .star => .multiply,
                .slash => .divide,
                else => unreachable,
            };
        try self.emitByte(allocator, @intFromEnum(op));
    }

    fn grouping(self: *Parser, allocator: Allocator) !void {
        try self.expression(allocator);
        try self.consume(.right_paren, "Expect ')' after expression.");
    }

    fn number(self: *Parser, allocator: Allocator) !void {
        const value = try std.fmt.parseFloat(Value, self.previous.lexeme);
        try self.emitConstant(allocator, value);
    }

    fn unary(self: *Parser, allocator: Allocator) !void {
        const operator_type = self.previous.token_type;

        // Compile the operand.
        try self.parsePrecedence(allocator, .unary);

        // Emit the operator instruction.
        switch (operator_type) {
            .minus => try self.emitByte(allocator, @intFromEnum(OpCode.negate)),
            else => unreachable,
        }
    }

    fn parsePrecedence(self: *Parser, allocator: Allocator, precedence: Precedence) !void {
        try self.advance();
        if (getRule(self.previous.token_type).prefix) |prefix_rule| {
            try prefix_rule(self, allocator);
        } else {
            try self.errorAtPrevious("Expect expression.");
            return;
        }

        while (precedence.le(getRule(self.current.token_type).precedence)) {
            try self.advance();
            const infix_rule = getRule(self.current.token_type).infix;
            try infix_rule.?(self, allocator);
        }
    }

    fn getRule(token_type: TokenType) ParseRule {
        return switch (token_type) {
            .left_paren => .{ .prefix = grouping, .infix = null, .precedence = .none },
            .minus => .{ .prefix = unary, .infix = binary, .precedence = .term },
            .plus, .slash, .star => .{ .prefix = null, .infix = binary, .precedence = .term },
            .number => .{ .prefix = number, .infix = null, .precedence = .none },
            else => .{ .prefix = null, .infix = null, .precedence = .none },
        };
    }

    pub fn expression(self: *Parser, allocator: Allocator) !void {
        try self.parsePrecedence(allocator, .assignment);
    }
};

pub fn compile(allocator: Allocator, source: []const u8, chunk: *Chunk) !void {
    var scanner = Scanner.init(source);
    var parser = Parser{
        .scanner = &scanner,
        .compiling_chunk = chunk,
    };
    try parser.advance();
    try parser.expression(allocator);
    try parser.consume(.eof, "Expect end of expression.");
    try parser.endCompiler(allocator);
}
