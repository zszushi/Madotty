//! Per-pane OSC 9;4 state and the value shown by the tab and taskbar.
const Progress = @This();
const std = @import("std");

pub const Report = @import("../../terminal/osc.zig").Command.ProgressReport;

state: Report.State = .remove,
value: u8 = 0,

pub fn apply(self: *Progress, report: Report) bool {
    const value = @min(report.progress orelse 0, 100);
    const next: Progress = .{
        .state = report.state,
        .value = switch (report.state) {
            .remove => 0,
            .set => value,
            .indeterminate => self.value,
            .@"error", .pause => if (value != 0) value else if (self.value != 0) self.value else 10,
        },
    };
    if (std.meta.eql(self.*, next)) return false;
    self.* = next;
    return true;
}

fn priority(state: Report.State) u8 {
    return switch (state) {
        .remove => 0,
        .indeterminate => 1,
        .set => 2,
        .pause => 3,
        .@"error" => 4,
    };
}

/// Follow the shell's priority for grouped buttons. Equal determinate
/// statuses show the least-complete operation, independent of focus.
pub fn preferred(a: Progress, b: Progress) Progress {
    const order = std.math.order(priority(a.state), priority(b.state));
    const chosen = switch (order) {
        .lt => b,
        .gt => a,
        .eq => if (b.value < a.value) b else a,
    };
    return if (chosen.state == .indeterminate) .{ .state = .indeterminate } else chosen;
}

test "win32 progress reports retain the owning pane value" {
    const testing = std.testing;
    var item: Progress = .{};
    try testing.expect(!item.apply(.{ .state = .remove }));
    try testing.expect(item.apply(.{ .state = .set, .progress = 42 }));
    try testing.expect(!item.apply(.{ .state = .set, .progress = 42 }));
    try testing.expect(item.apply(.{ .state = .indeterminate }));
    try testing.expectEqual(42, item.value);
    try testing.expect(item.apply(.{ .state = .pause }));
    try testing.expectEqual(42, item.value);
    try testing.expect(item.apply(.{ .state = .@"error", .progress = 0 }));
    try testing.expectEqual(42, item.value);
    try testing.expect(item.apply(.{ .state = .remove }));
    try testing.expectEqual(0, item.value);
    try testing.expect(item.apply(.{ .state = .@"error" }));
    try testing.expectEqual(10, item.value);
    try testing.expect(item.apply(.{ .state = .set, .progress = 255 }));
    try testing.expectEqual(100, item.value);
}

test "win32 progress aggregation survives unrelated clears and moved panes" {
    const testing = std.testing;
    const busy: Progress = .{ .state = .indeterminate, .value = 78 };
    const normal: Progress = .{ .state = .set, .value = 72 };
    const slower: Progress = .{ .state = .set, .value = 29 };
    const failed: Progress = .{ .state = .@"error", .value = 67 };
    const paused: Progress = .{ .state = .pause, .value = 43 };
    const cleared: Progress = .{};

    const tab_a = normal.preferred(slower);
    const tab_b = failed.preferred(paused);
    try testing.expectEqual(slower, tab_a);
    try testing.expectEqual(failed, tab_b);
    try testing.expectEqual(failed, tab_a.preferred(tab_b));
    try testing.expectEqual(failed, cleared.preferred(tab_b));
    try testing.expectEqual(slower, tab_a.preferred(cleared));
    try testing.expectEqual(paused, paused.preferred(tab_a));
    try testing.expectEqual(normal, busy.preferred(normal));
    try testing.expectEqual(Progress{ .state = .indeterminate }, cleared.preferred(busy));
}
