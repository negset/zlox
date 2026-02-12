const std = @import("std");
const Scanner = @import("scanner.zig").Scanner;

pub fn compile(source: []const u8) void {
    var scanner = Scanner.init(source);
    var line: u32 = undefined;
    while (true) {
        const token = scanner.scanToken();
        if (token.line != line) {
            std.debug.print("{d:>4} ", .{token.line});
            line = token.line;
        } else {
            std.debug.print("   | ", .{});
        }
        std.debug.print("{d:>2} '{s}'\n", .{
            token.token_type,
            token.lexeme,
        });

        if (token.token_type == .eof) break;
    }
}
