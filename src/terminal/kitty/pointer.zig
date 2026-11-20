//! Kitty pointer shape protocol (OSC 22).
//! https://sw.kovidgoyal.net/kitty/pointer-shapes/

const std = @import("std");
const Shape = @import("../mouse.zig").Shape;

pub const stack_capacity = 16;

pub const Capabilities = struct {
    default: Shape = .text,
    grabbed: Shape = .default,

    /// A frontend may filter shapes it cannot display. An absent callback
    /// allows all recognized shapes for clients that manage their own cursor.
    supported: ?*const fn (Shape) bool = null,

    fn supports(self: Capabilities, shape: Shape) bool {
        return if (self.supported) |check| check(shape) else true;
    }
};

pub const Request = union(enum) {
    set: []const u8,
    push: []const u8,
    pop,
    query: []const u8,
};

/// Parse the borrowed bytes following OSC 22's semicolon.
pub fn parse(payload: []const u8) Request {
    if (payload.len == 0) return .{ .set = payload };
    return switch (payload[0]) {
        '=' => .{ .set = payload[1..] },
        '>' => .{ .push = payload[1..] },
        '<' => .pop,
        '?' => .{ .query = payload[1..] },
        else => .{ .set = payload },
    };
}

pub const State = struct {
    main: Stack = .{},
    alternate: Stack = .{},

    /// Read the explicit override. An empty entry still occupies a stack slot
    /// so a later pop can restore the previously pushed shape.
    pub fn current(self: *const State, alternate: bool) ?Shape {
        return if (alternate) self.alternate.top() else self.main.top();
    }

    pub fn effective(self: *const State, alternate: bool, grabbed: bool, caps: Capabilities) Shape {
        return self.current(alternate) orelse if (grabbed) caps.grabbed else caps.default;
    }

    /// Replace the active stack entry with an already resolved shape.
    pub fn setShape(self: *State, alternate: bool, shape: ?Shape) void {
        const stack = if (alternate) &self.alternate else &self.main;
        stack.set(shape);
    }

    pub fn apply(self: *State, alternate: bool, request: Request, caps: Capabilities) void {
        const stack = if (alternate) &self.alternate else &self.main;
        switch (request) {
            .set => |names| {
                var split = std.mem.splitScalar(u8, names, ',');
                while (split.next()) |value| {
                    if (value.len == 0) {
                        stack.set(null);
                    } else if (Shape.fromString(value)) |shape| {
                        if (caps.supports(shape)) stack.set(shape);
                    }
                }
            },
            .push => |names| {
                var split = std.mem.splitScalar(u8, names, ',');
                while (split.next()) |value| {
                    const shape = Shape.fromString(value) orelse continue;
                    if (caps.supports(shape)) stack.push(shape);
                }
            },
            .pop => stack.pop(),
            .query => {},
        }
    }

    /// Write one OSC 22 reply with ST, as used by kitty. Each query token,
    /// including an empty token, produces an answer in the same position.
    pub fn writeResponse(
        self: *const State,
        alternate: bool,
        query: []const u8,
        caps: Capabilities,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b]22;");
        var split = std.mem.splitScalar(u8, query, ',');
        while (split.next()) |value| {
            const answer = if (std.mem.eql(u8, value, "__current__"))
                if (self.current(alternate)) |shape| name(shape) else "0"
            else if (std.mem.eql(u8, value, "__default__"))
                name(caps.default)
            else if (std.mem.eql(u8, value, "__grabbed__"))
                name(caps.grabbed)
            else if (Shape.fromString(value)) |shape|
                if (caps.supports(shape)) "1" else "0"
            else
                "0";
            try writer.writeAll(answer);
            if (split.peek() != null) try writer.writeByte(',');
        }
        try writer.writeAll("\x1b\\");
    }
};

const Stack = struct {
    entries: [stack_capacity]?Shape = undefined,
    first: usize = 0,
    len: usize = 0,

    fn index(self: *const Stack, offset: usize) usize {
        return (self.first + offset) % stack_capacity;
    }

    fn top(self: *const Stack) ?Shape {
        if (self.len == 0) return null;
        return self.entries[self.index(self.len - 1)];
    }

    fn set(self: *Stack, shape: ?Shape) void {
        if (self.len == 0) return self.push(shape);
        self.entries[self.index(self.len - 1)] = shape;
    }

    fn push(self: *Stack, shape: ?Shape) void {
        self.entries[self.index(self.len)] = shape;
        if (self.len < stack_capacity) {
            self.len += 1;
        } else {
            self.first = self.index(1);
        }
    }

    fn pop(self: *Stack) void {
        if (self.len > 0) self.len -= 1;
    }
};

fn name(shape: Shape) []const u8 {
    return switch (shape) {
        inline else => |tag| comptime css: {
            var bytes = @tagName(tag)[0..@tagName(tag).len].*;
            for (&bytes) |*byte| {
                if (byte.* == '_') byte.* = '-';
            }
            const result = bytes;
            break :css &result;
        },
    };
}

test "kitty pointer shape set, push, pop, fallback and separate screens" {
    const t = std.testing;
    var state: State = .{};
    const caps: Capabilities = .{};
    try t.expectEqual(null, state.current(false));
    try t.expectEqual(Shape.text, state.effective(false, false, caps));
    try t.expectEqual(Shape.default, state.effective(false, true, caps));

    state.apply(false, parse("hand"), caps);
    state.apply(false, parse(">wait,unknown,,ne-resize"), caps);
    state.apply(true, parse("=crosshair"), caps);
    try t.expectEqual(Shape.ne_resize, state.effective(false, true, caps));
    try t.expectEqual(Shape.crosshair, state.current(true));
    state.apply(false, parse(""), caps);
    try t.expectEqual(null, state.current(false));
    state.apply(false, parse("<anything,or,many"), caps);
    try t.expectEqual(Shape.wait, state.current(false));
    state.apply(false, parse("<"), caps);
    try t.expectEqual(Shape.pointer, state.current(false));
    state.apply(false, parse("<"), caps);
    state.apply(false, parse("<"), caps);
    try t.expectEqual(null, state.current(false));
    try t.expectEqual(Shape.crosshair, state.current(true));
}

test "kitty pointer shape evicts the oldest stack entry" {
    const t = std.testing;
    var state: State = .{};
    state.apply(false, parse("text"), .{});
    state.apply(false, parse(">pointer"), .{});
    for (0..stack_capacity - 1) |_| state.apply(false, parse(">wait"), .{});
    for (0..stack_capacity - 1) |_| state.apply(false, parse("<"), .{});
    try t.expectEqual(Shape.pointer, state.current(false));
    state.apply(false, parse("<"), .{});
    try t.expectEqual(null, state.current(false));
}

test "kitty pointer shape query wire, canonical names and capability filtering" {
    const t = std.testing;
    const caps: Capabilities = .{
        .supported = &struct {
            fn check(shape: Shape) bool {
                return shape != .zoom_in;
            }
        }.check,
    };
    var state: State = .{};
    state.apply(false, parse("=top_right_corner"), caps);
    state.apply(false, parse(">zoom-in"), caps);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const q = parse("?__current__,__default__,__grabbed__,hand,zoom-in,fake,");
    try state.writeResponse(false, q.query, caps, &writer);
    try t.expectEqualStrings("\x1b]22;ne-resize,text,default,1,0,0,0\x1b\\", writer.buffered());

    writer = .fixed(&buffer);
    try state.writeResponse(true, "__current__", caps, &writer);
    try t.expectEqualStrings("\x1b]22;0\x1b\\", writer.buffered());
}
