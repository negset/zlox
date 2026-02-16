const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const Value = @import("value.zig").Value;

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
};

const Parser = struct {
    scanner: *Scanner,
    compiling_chunk: *Chunk,
    current: Token = undefined,
    previous: Token = undefined,
    had_error: bool = false,

    fn errorAt(self: *Parser, token: Token, message: []const u8) void {
        std.debug.print("[line {d}] Error", .{token.line});

        switch (token.token_type) {
            .eof => std.debug.print(" at end", .{}),
            .@"error" => {}, // Nothing.
            else => std.debug.print(" at '{s}'", .{token.lexeme}),
        }

        std.debug.print(": {s}\n", .{message});
        self.had_error = true;
    }

    fn errorAtPrevious(self: *Parser, message: []const u8) void {
        self.errorAt(self.previous, message);
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) void {
        self.errorAt(self.current, message);
    }

    pub fn advance(self: *Parser) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scanToken();
            if (self.current.token_type != .@"error") break;

            self.errorAtCurrent(self.current.lexeme);
        }
    }

    pub fn consume(self: *Parser, token_type: TokenType, message: []const u8) void {
        if (self.current.token_type == token_type) {
            self.advance();
            return;
        }

        self.errorAtCurrent(message);
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
            self.errorAtPrevious("Too many constants in one chunk.");
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
    }

    fn grouping(self: *Parser, allocator: Allocator) !void {
        try self.expression(allocator);
        self.consume(.right_paren, "Expect ')' after expression.");
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

    fn parsePrecedence(self: *Parser, allocator: Allocator, precedence: Precedence) void {
        //
        _ = self;
        _ = allocator;
        _ = precedence;
    }

    pub fn expression(self: *Parser, allocator: Allocator) !void {
        self.parsePrecedence(allocator, .assignment);
    }
};

pub fn compile(allocator: Allocator, source: []const u8, chunk: *Chunk) bool {
    var scanner = Scanner.init(source);

    var parser: Parser = .{
        .scanner = &scanner,
        .compiling_chunk = chunk,
    };
    parser.advance();
    parser.expression(allocator) catch @panic("TODO");
    parser.consume(.eof, "Expect end of expression.");
    parser.endCompiler(allocator) catch @panic("TODO");
    return !parser.had_error;
}
