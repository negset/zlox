const std = @import("std");

pub const TokenType = enum {
    // single-character tokens.
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    comma,
    dot,
    minus,
    plus,
    semicolon,
    slash,
    star,
    // One or two character tokens.
    bang,
    bang_equal,
    equal,
    equal_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    // Literals.
    identifier,
    string,
    number,
    // Keywords.
    @"and",
    class,
    @"else",
    false,
    @"for",
    fun,
    @"if",
    nil,
    @"or",
    print,
    @"return",
    super,
    this,
    true,
    @"var",
    @"while",

    @"error",
    eof,
};

pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    line: u32,
};

pub const Scanner = struct {
    source: []const u8,
    start: usize,
    current: usize,
    line: u32,

    pub fn init(source: []const u8) Scanner {
        return .{
            .source = source,
            .start = 0,
            .current = 0,
            .line = 1,
        };
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '_';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAtEnd(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Scanner) void {
        self.current += 1;
    }

    fn peek(self: *Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Scanner) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn makeToken(self: *Scanner, token_type: TokenType) Token {
        return .{
            .token_type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.line,
        };
    }

    fn errorToken(self: *Scanner, message: []const u8) Token {
        return .{
            .token_type = .@"error",
            .lexeme = message,
            .line = self.line,
        };
    }

    fn skipWhiteSpace(self: *Scanner) void {
        while (true) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => self.advance(),
                '\n' => {
                    self.line += 1;
                    self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        // A comment goes until the end of then line.
                        while (self.peek() != '\n' and !self.isAtEnd()) self.advance();
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn checkKeyword(self: *Scanner, start: usize, rest: []const u8, token_type: TokenType) TokenType {
        if (self.current - self.start == start + rest.len and
            std.mem.startsWith(u8, self.source[self.start + start ..], rest))
        {
            return token_type;
        }

        return .identifier;
    }

    fn identifierType(self: *Scanner) TokenType {
        return switch (self.source[self.start]) {
            'a' => self.checkKeyword(1, "nd", .@"and"),
            'c' => self.checkKeyword(1, "lass", .class),
            'e' => self.checkKeyword(1, "lse", .@"else"),
            'f' =>
            // Check that there is a second character.
            if (self.current - self.start > 1)
                switch (self.source[self.start + 1]) {
                    'a' => self.checkKeyword(2, "lse", .false),
                    'o' => self.checkKeyword(2, "r", .@"for"),
                    'u' => self.checkKeyword(2, "n", .fun),
                    else => .identifier,
                }
            else
                .identifier,
            'i' => self.checkKeyword(1, "f", .@"if"),
            'n' => self.checkKeyword(1, "il", .nil),
            'o' => self.checkKeyword(1, "r", .@"or"),
            'p' => self.checkKeyword(1, "rint", .print),
            'r' => self.checkKeyword(1, "eturn", .@"return"),
            's' => self.checkKeyword(1, "uper", .super),
            't' =>
            // Check that there is a second character.
            if (self.current - self.start > 1)
                switch (self.source[self.start + 1]) {
                    'h' => self.checkKeyword(2, "is", .this),
                    'r' => self.checkKeyword(2, "ue", .true),
                    else => .identifier,
                }
            else
                .identifier,
            'v' => self.checkKeyword(1, "ar", .@"var"),
            'w' => self.checkKeyword(1, "hile", .@"while"),
            else => .identifier,
        };
    }

    fn identifier(self: *Scanner) Token {
        while (isAlpha(self.peek()) or isDigit(self.peek())) self.advance();
        return self.makeToken(self.identifierType());
    }

    fn number(self: *Scanner) Token {
        while (isDigit(self.peek())) self.advance();

        // Look for a fractional part.
        if (self.peek() == '.' and isDigit(self.peekNext())) {
            // Consume the ".".
            self.advance();

            while (isDigit(self.peek())) self.advance();
        }

        return self.makeToken(.number);
    }

    fn string(self: *Scanner) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            self.advance();
        }

        if (self.isAtEnd()) return self.errorToken("Unterminated string.");

        // The closing quote.
        self.advance();
        return self.makeToken(.string);
    }

    pub fn scanToken(self: *Scanner) Token {
        self.skipWhiteSpace();
        self.start = self.current;

        if (self.isAtEnd()) return self.makeToken(.eof);

        const c = self.peek();
        self.advance();
        if (isAlpha(c)) return self.identifier();
        if (isDigit(c)) return self.number();

        const token_type: TokenType = switch (c) {
            '(' => .left_paren,
            ')' => .right_paren,
            '{' => .left_brace,
            '}' => .right_brace,
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot,
            '-' => .minus,
            '+' => .plus,
            '/' => .slash,
            '*' => .star,
            '!' => if (self.match('=')) .bang_equal else .bang,
            '=' => if (self.match('=')) .equal_equal else .equal,
            '<' => if (self.match('=')) .less_equal else .less,
            '>' => if (self.match('=')) .greater_equal else .greater,
            '"' => return self.string(),
            else => return self.errorToken("Unexpected character."),
        };
        return self.makeToken(token_type);
    }
};
