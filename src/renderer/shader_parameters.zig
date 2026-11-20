//! Opt-in scalar controls for ShaderToy-style GLSL files.
const std = @import("std");
const compat_file = @import("../lib/compat/file.zig");
const global = @import("../global.zig");
const Allocator = std.mem.Allocator;

pub const Parameter = struct {
    name: []const u8,
    label: []const u8,
    default: f64,
    min: f64,
    max: f64,
    step: f64,
    integer: bool,

    pub fn accepts(self: Parameter, value: f64) bool {
        if (!std.math.isFinite(value) or value < self.min or value > self.max) return false;
        if (self.integer) return value == @trunc(value) and value >= std.math.minInt(i32) and value <= std.math.maxInt(i32);
        if (@abs(value) > std.math.floatMax(f32)) return false;
        const rounded: f32 = @floatCast(value);
        return rounded != 0 or value == 0;
    }
};

pub const Override = struct {
    /// One-based position in the configured custom-shader list.
    pass: usize,
    name: []const u8,
    value: f64,
};

pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or !identifierStart(name[0])) return false;
    for (name[1..]) |byte| if (!identifierByte(byte)) return false;
    return true;
}

fn identifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn identifierByte(byte: u8) bool {
    return identifierStart(byte) or std.ascii.isDigit(byte);
}

/// Parse PASS:NAME:VALUE. The returned name borrows text.
pub fn parseOverride(text: []const u8) !Override {
    var fields = std.mem.splitScalar(u8, text, ':');
    const pass_text = fields.next().?;
    if (pass_text.len == 0) return error.InvalidShaderOverride;
    for (pass_text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidShaderOverride;
    const pass = std.fmt.parseInt(usize, pass_text, 10) catch return error.InvalidShaderOverride;
    const name = fields.next() orelse return error.InvalidShaderOverride;
    const value = decimal(fields.next() orelse return error.InvalidShaderOverride) orelse return error.InvalidShaderOverride;
    if (pass == 0 or !isIdentifier(name) or fields.next() != null) return error.InvalidShaderOverride;
    return .{ .pass = pass, .name = name, .value = value };
}

pub fn readSource(alloc: Allocator, path: []const u8) ![]u8 {
    const io = global.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return compat_file.readToEndAlloc(file, alloc, 4 * 1024 * 1024);
}

/// Returns owned parameters and strings. Release them with deinit.
pub fn inspectFile(alloc: Allocator, path: []const u8) ![]const Parameter {
    const src = try readSource(alloc, path);
    defer alloc.free(src);
    return inspect(alloc, src);
}

pub fn inspect(alloc: Allocator, src: []const u8) ![]const Parameter {
    const entries = try discover(alloc, src);
    defer alloc.free(entries);
    const result = try alloc.alloc(Parameter, entries.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| {
            alloc.free(item.name);
            alloc.free(item.label);
        }
        alloc.free(result);
    }
    for (entries, result) |entry, *item| {
        item.* = entry.parameter;
        item.name = try alloc.dupe(u8, item.name);
        errdefer alloc.free(item.name);
        item.label = try alloc.dupe(u8, item.label);
        initialized += 1;
    }
    return result;
}

pub fn deinit(alloc: Allocator, parameters: []const Parameter) void {
    for (parameters) |item| {
        alloc.free(item.name);
        alloc.free(item.label);
    }
    alloc.free(parameters);
}

/// Replaces only numeric tokens in recognized global initializers. A null
/// result means the caller can compile the original bytes.
pub fn rewrite(alloc: Allocator, src: []const u8, pass: usize, overrides: []const Override) !?[]u8 {
    for (overrides) |entry| {
        if (entry.pass == pass) break;
    } else return null;

    const entries = try discover(alloc, src);
    defer alloc.free(entries);
    std.mem.sort(Entry, entries, {}, Entry.lessByOffset);

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    var cursor: usize = 0;
    for (entries) |entry| {
        const parameter = entry.parameter;
        const value = value: {
            for (0..overrides.len) |index| {
                const candidate = overrides[overrides.len - 1 - index];
                if (candidate.pass == pass and std.mem.eql(u8, candidate.name, parameter.name) and
                    parameter.accepts(candidate.value)) break :value candidate.value;
            }
            continue;
        };
        const literal = entry.literal.?;
        if (literal.sign) |offset| {
            try writer.writer.writeAll(src[cursor..offset]);
            try writer.writer.writeByte(' ');
            cursor = offset + 1;
        }
        try writer.writer.writeAll(src[cursor..literal.start]);
        if (parameter.integer) {
            try writer.writer.print("{d}", .{@as(i32, @intFromFloat(value))});
        } else {
            try writer.writer.print("{e}", .{@as(f32, @floatCast(value))});
        }
        cursor = literal.end;
    }
    if (cursor == 0) return null;
    try writer.writer.writeAll(src[cursor..]);
    return try writer.toOwnedSlice();
}

const Literal = struct {
    sign: ?usize,
    start: usize,
    end: usize,
};

const Entry = struct {
    parameter: Parameter,
    literal: ?Literal = null,

    fn lessByOffset(_: void, a: Entry, b: Entry) bool {
        return a.literal.?.start < b.literal.?.start;
    }
};

fn discover(alloc: Allocator, src: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(alloc);
    var lexer: Lexer = .{ .source = src };
    var scope: Scope = .{};
    while (lexer.next()) |token| {
        if (token.kind != .directive) {
            scope.advance(token.text(src));
            continue;
        }
        const command, const arguments = directiveParts(token.text(src));
        if (scope.topLevel() and std.mem.eql(u8, command, "pragma")) {
            var pragma = arguments;
            if (std.mem.eql(u8, takeWord(&pragma), "parameter")) {
                const parameter = parsePragma(pragma) orelse return error.InvalidShaderParameter;
                if (find(entries.items, parameter.name) != null) return error.InvalidShaderParameter;
                try entries.append(alloc, .{ .parameter = parameter });
            }
        }
        scope.advanceDirective(command);
    }
    if (entries.items.len == 0) return entries.toOwnedSlice(alloc);

    lexer = .{ .source = src };
    scope = .{};
    while (lexer.next()) |token| {
        const text = token.text(src);
        if (token.kind == .directive) {
            const command, _ = directiveParts(text);
            scope.advanceDirective(command);
            continue;
        }
        if (scope.topLevel() and std.mem.eql(u8, text, "const")) {
            try matchDeclaration(lexer, entries.items);
        }
        scope.advance(text);
    }

    for (entries.items) |entry| if (entry.literal == null) return error.InvalidShaderParameter;
    return entries.toOwnedSlice(alloc);
}

fn matchDeclaration(snapshot: Lexer, entries: []Entry) !void {
    var lexer = snapshot;
    const src = lexer.source;
    const type_token = lexer.next() orelse return;
    const integer = if (std.mem.eql(u8, type_token.text(src), "int"))
        true
    else if (std.mem.eql(u8, type_token.text(src), "float"))
        false
    else
        return;
    const name = lexer.next() orelse return;
    const entry = find(entries, name.text(src)) orelse return;
    if (entry.literal != null) return error.InvalidShaderParameter;
    if (!lexer.eat("=")) return error.InvalidShaderParameter;
    var token = lexer.next() orelse return error.InvalidShaderParameter;
    const negative = std.mem.eql(u8, token.text(src), "-");
    const sign = if (negative or std.mem.eql(u8, token.text(src), "+")) token.start else null;
    if (sign != null) token = lexer.next() orelse return error.InvalidShaderParameter;
    if (token.kind != .number or !lexer.eat(";")) return error.InvalidShaderParameter;
    const magnitude = scalarLiteral(token.text(src), integer) orelse return error.InvalidShaderParameter;
    const initial = if (negative) -magnitude else magnitude;
    entry.parameter.integer = integer;
    if (!entry.parameter.accepts(initial) or
        !entry.parameter.accepts(entry.parameter.min) or
        !entry.parameter.accepts(entry.parameter.max) or
        (if (integer) initial != entry.parameter.default else @as(f32, @floatCast(initial)) != @as(f32, @floatCast(entry.parameter.default))) or
        (integer and (entry.parameter.step != @trunc(entry.parameter.step) or entry.parameter.step > std.math.maxInt(i32))))
    {
        return error.InvalidShaderParameter;
    }
    entry.literal = .{ .sign = sign, .start = token.start, .end = token.end };
}

fn find(entries: []Entry, name: []const u8) ?*Entry {
    for (entries) |*entry| if (std.mem.eql(u8, entry.parameter.name, name)) return entry;
    return null;
}

fn parsePragma(args: []const u8) ?Parameter {
    var rest = args;
    const name = takeWord(&rest);
    if (!isIdentifier(name) or rest.len == 0 or rest[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    const label = rest[1..close];
    if (label.len == 0 or !std.unicode.utf8ValidateSlice(label) or std.mem.indexOfScalar(u8, label, 0) != null) return null;
    if (rest.len <= close + 1 or !std.ascii.isWhitespace(rest[close + 1])) return null;
    rest = rest[close + 1 ..];

    const default = decimal(takeWord(&rest)) orelse return null;
    const min = decimal(takeWord(&rest)) orelse return null;
    const max = decimal(takeWord(&rest)) orelse return null;
    const step = decimal(takeWord(&rest)) orelse return null;
    var tail: Lexer = .{ .source = rest };
    if (tail.next() != null or min > default or default > max or step <= 0) return null;
    return .{ .name = name, .label = label, .default = default, .min = min, .max = max, .step = step, .integer = false };
}

fn directiveParts(line: []const u8) struct { []const u8, []const u8 } {
    const rest = std.mem.trimStart(u8, line[1..], " \t");
    var end: usize = 0;
    while (end < rest.len and identifierByte(rest[end])) end += 1;
    return .{ rest[0..end], rest[end..] };
}

fn takeWord(input: *[]const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, input.*, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    input.* = std.mem.trimStart(u8, trimmed[end..], " \t\r\n");
    return trimmed[0..end];
}

fn decimal(input: []const u8) ?f64 {
    if (input.len == 0) return null;
    for (input) |byte| switch (byte) {
        '0'...'9', '-', '+', '.', 'e', 'E' => {},
        else => return null,
    };
    const value = std.fmt.parseFloat(f64, input) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

fn scalarLiteral(text: []const u8, integer: bool) ?f64 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        const value = std.fmt.parseInt(u32, text[2..], 16) catch return null;
        return @floatFromInt(value);
    }
    if (!integer and std.mem.indexOfAny(u8, text, ".eEfF") != null) {
        const trimmed = if (std.ascii.toLower(text[text.len - 1]) == 'f') text[0 .. text.len - 1] else text;
        return decimal(trimmed);
    }
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const value = std.fmt.parseInt(u32, text, if (text.len > 1 and text[0] == '0') 8 else 10) catch return null;
    return @floatFromInt(value);
}

const Scope = struct {
    braces: usize = 0,
    parens: usize = 0,
    brackets: usize = 0,
    conditional: usize = 0,

    fn topLevel(self: Scope) bool {
        return self.braces == 0 and self.parens == 0 and self.brackets == 0 and self.conditional == 0;
    }

    fn advance(self: *Scope, text: []const u8) void {
        if (text.len != 1) return;
        switch (text[0]) {
            '{' => self.braces += 1,
            '}' => self.braces -|= 1,
            '(' => self.parens += 1,
            ')' => self.parens -|= 1,
            '[' => self.brackets += 1,
            ']' => self.brackets -|= 1,
            else => {},
        }
    }

    fn advanceDirective(self: *Scope, command: []const u8) void {
        if (std.mem.eql(u8, command, "endif")) self.conditional -|= 1;
        for ([_][]const u8{ "if", "ifdef", "ifndef" }) |start| {
            if (std.mem.eql(u8, command, start)) {
                self.conditional += 1;
                break;
            }
        }
    }
};

const Lexer = struct {
    source: []const u8,
    cursor: usize = 0,

    const Token = struct {
        kind: enum { directive, number, other },
        start: usize,
        end: usize,

        fn text(self: Token, source: []const u8) []const u8 {
            return source[self.start..self.end];
        }
    };

    fn eat(self: *Lexer, expected: []const u8) bool {
        const token = self.next() orelse return false;
        return std.mem.eql(u8, token.text(self.source), expected);
    }

    fn next(self: *Lexer) ?Token {
        const src = self.source;
        while (self.cursor < src.len) {
            const tail = src[self.cursor..];
            if (std.ascii.isWhitespace(tail[0])) {
                self.cursor += 1;
            } else if (std.mem.startsWith(u8, tail, "//")) {
                self.cursor += std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len;
            } else if (std.mem.startsWith(u8, tail, "/*")) {
                self.cursor += if (std.mem.indexOfPos(u8, tail, 2, "*/")) |end| end + 2 else tail.len;
            } else break;
        }
        if (self.cursor == src.len) return null;
        const start = self.cursor;
        const c = src[start];
        self.cursor += 1;
        if (c == '#') {
            while (std.mem.indexOfScalarPos(u8, src, self.cursor, '\n')) |end| {
                self.cursor = end;
                const last = if (end > start and src[end - 1] == '\r') end - 1 else end;
                if (last == start or src[last - 1] != '\\') break;
                self.cursor += 1;
            } else self.cursor = src.len;
            return .{ .kind = .directive, .start = start, .end = self.cursor };
        }
        if (identifierStart(c)) {
            while (self.cursor < src.len and identifierByte(src[self.cursor])) self.cursor += 1;
        } else if (std.ascii.isDigit(c) or c == '.') {
            while (self.cursor < src.len) : (self.cursor += 1) {
                const byte = src[self.cursor];
                if (identifierByte(byte) or byte == '.') continue;
                if ((byte == '+' or byte == '-') and std.ascii.toLower(src[self.cursor - 1]) == 'e') continue;
                break;
            }
            return .{ .kind = .number, .start = start, .end = self.cursor };
        }
        return .{ .kind = .other, .start = start, .end = self.cursor };
    }
};

test "custom shader parameters inspect annotated global literals" {
    const alloc = std.testing.allocator;
    const src =
        \\/* #pragma parameter GHOST "Comment" 0 0 1 0.1 */
        \\const float GAIN = 0.25;
        \\#pragma parameter GAIN "Gain" 0.25 0 1 0.05
        \\#pragma parameter COUNT "Samples" 8 1 32 1
        \\const int COUNT = 0x08;
        \\void f(const float GAIN) { const int COUNT = 11; }
    ;
    const parameters = try inspect(alloc, src);
    defer deinit(alloc, parameters);
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    try std.testing.expectEqualStrings("GAIN", parameters[0].name);
    try std.testing.expectEqualStrings("Gain", parameters[0].label);
    try std.testing.expectEqual(@as(f64, 0.25), parameters[0].default);
    try std.testing.expect(parameters[0].accepts(0.8));
    try std.testing.expect(!parameters[0].accepts(1e-100));
    try std.testing.expect(parameters[1].integer);
    try std.testing.expect(parameters[1].accepts(32));
    try std.testing.expect(!parameters[1].accepts(2.5));
}

test "custom shader parameters rewrite only declared literals using last valid override" {
    const alloc = std.testing.allocator;
    const src = "#pragma parameter GAIN \"Gain\" -0.25 -1 1 0.05\r\n" ++
        "#pragma parameter COUNT \"Samples\" 8 1 32 1\r\n" ++
        "const int COUNT = 8;\r\nconst float GAIN = - /* keep this */\r\n0.25;\r\n" ++
        "void f() { const float GAIN = 0.99; }\r\n";
    const overrides = [_]Override{
        try parseOverride("2:GAIN:-0.5"),
        try parseOverride("1:GAIN:0.75"),
        try parseOverride("1:GAIN:3"),
        try parseOverride("1:COUNT:12"),
        try parseOverride("1:COUNT:12.5"),
    };
    const changed = (try rewrite(alloc, src, 1, &overrides)).?;
    defer alloc.free(changed);
    try std.testing.expectEqualStrings(
        "#pragma parameter GAIN \"Gain\" -0.25 -1 1 0.05\r\n" ++
            "#pragma parameter COUNT \"Samples\" 8 1 32 1\r\n" ++
            "const int COUNT = 12;\r\nconst float GAIN =   /* keep this */\r\n7.5e-1;\r\n" ++
            "void f() { const float GAIN = 0.99; }\r\n",
        changed,
    );
    try std.testing.expectEqual(@as(?[]u8, null), try rewrite(alloc, src, 3, &overrides));
}

test "custom shader parameters reject malformed controls and unsafe overrides" {
    const alloc = std.testing.allocator;
    const pragma = "#pragma parameter GAIN \"Gain\" 0.25 0 1 0.05\n";
    for ([_][]const u8{
        pragma ++ "void f() { const float GAIN = 0.25; }",
        pragma ++ "#if(FOO)\nconst float GAIN = 0.25;\n#endif",
        pragma ++ "const float GAIN = 0.2 + 0.05;",
        pragma ++ "const float GAIN = 0.75;",
        pragma ++ pragma ++ "const float GAIN = 0.25;",
        pragma ++ "const float GAIN = 0.25, OTHER = 0.5;",
    }) |source| try std.testing.expectError(error.InvalidShaderParameter, inspect(alloc, source));

    for ([_][]const u8{ "0:GAIN:1", "1:GAIN:NaN", "1:GAIN:1:2", "1:GAIN:1;", "1:1GAIN:1", "1:GAIN:1e999" }) |input|
        try std.testing.expectError(error.InvalidShaderOverride, parseOverride(input));
}
