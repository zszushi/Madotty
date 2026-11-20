const std = @import("std");
const options = @import("main.zig").options;
const run = @import("shaper/run.zig");
const feature = @import("shaper/feature.zig");
const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");
const unicode = @import("../unicode/main.zig");
const SharedGrid = @import("main.zig").SharedGrid;
pub const noop = @import("shaper/noop.zig");
pub const harfbuzz = @import("shaper/harfbuzz.zig");
pub const coretext = @import("shaper/coretext.zig");
pub const web_canvas = @import("shaper/web_canvas.zig");
pub const Cache = @import("shaper/Cache.zig");
pub const TextRun = run.TextRun;
pub const RunIterator = run.RunIterator;
pub const Feature = feature.Feature;
pub const FeatureList = feature.FeatureList;
pub const default_features = feature.default_features;

/// Shaper implementation for our compile options.
pub const Shaper = switch (options.backend) {
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    .coretext_harfbuzz,
    => harfbuzz.Shaper,

    // Note that coretext_freetype cannot use the coretext
    // shaper because the coretext shaper requests CoreText
    // font faces.
    .coretext => coretext.Shaper,

    .coretext_noshape => noop.Shaper,

    .web_canvas => web_canvas.Shaper,
};

/// A cell is a single glyph within a terminal that should be rendered
/// for a shaping call. Not all terminal cells may be present; only
/// cells that have a glyph that needs to be rendered.
pub const Cell = struct {
    /// The X position of this shaper cell relative to the offset of the
    /// run. Because runs are always within a single row, it is expected
    /// that the caller can reconstruct the full position of the cell by
    /// using the known Y position of the cell and adding the X position
    /// to the run offset.
    x: u16,

    /// An additional offset to apply to the rendering.
    x_offset: i16 = 0,
    y_offset: i16 = 0,

    /// The glyph index for this cell. The font index to use alongside
    /// this cell is available in the text run. This glyph index is only
    /// valid for a given GroupCache and FontIndex that was used to create
    /// the runs.
    glyph_index: u32,
};

/// Options for shapers.
pub const Options = struct {
    /// Font features to use when shaping.
    ///
    /// Note: eventually, this will move to font.Face probably as we may
    /// want to support per-face feature configuration. For now, we only
    /// support applying features globally.
    features: []const []const u8 = &.{},
};

/// Options for runIterator.
pub const RunOptions = struct {
    /// The font state for the terminal screen. This is mutable because
    /// cached values may be updated during shaping.
    grid: *SharedGrid,

    /// The cells for the row to shape.
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice = .empty,

    /// The x boundaries of the selection in this row.
    selection: ?[2]u16 = null,

    /// The cursor position within this row. This is used to break shaping
    /// on cursor boundaries. This can be disabled by setting this to
    /// null.
    cursor_x: ?usize = null,

    /// Explicit-width text may use the configured text ligatures; the
    /// surrounding fixed grid retains its usual breaks.
    allow_text_ligatures: bool = false,

    /// Apply the font break configuration to the run.
    pub fn applyBreakConfig(
        self: *RunOptions,
        config: configpkg.FontShapingBreak,
    ) void {
        if (!config.cursor) self.cursor_x = null;
    }
};

/// Reusable shaping input for one horizontal OSC 66 block. The renderer
/// clips the last cluster if its natural width exceeds the explicit width.
pub const SizedCells = struct {
    codepoints: std.ArrayList(u21) = .empty,
    cells: std.MultiArrayList(terminal.RenderState.Cell) = .empty,

    pub fn deinit(self: *SizedCells, alloc: std.mem.Allocator) void {
        self.codepoints.deinit(alloc);
        self.cells.deinit(alloc);
    }

    pub fn build(
        self: *SizedCells,
        alloc: std.mem.Allocator,
        head: terminal.page.Cell,
        extra: []const u21,
        style: terminal.Style,
        width: u3,
    ) std.mem.Allocator.Error!std.MultiArrayList(terminal.RenderState.Cell).Slice {
        self.codepoints.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        try self.codepoints.ensureUnusedCapacity(alloc, extra.len + 1);
        self.codepoints.appendAssumeCapacity(head.codepoint());
        self.codepoints.appendSliceAssumeCapacity(extra);
        // A two-cell glyph may start in the last visible column.
        try self.cells.ensureUnusedCapacity(alloc, @as(usize, width) + 1);

        var remaining: []const u21 = self.codepoints.items;
        while (remaining.len != 0 and self.cells.len < width) {
            const cluster = unicode.graphemeWidth(u21, remaining);
            const wide = cluster.width == 2;
            self.cells.appendAssumeCapacity(.{
                .raw = .{
                    .content = .{ .codepoint = .{ .data = remaining[0] } },
                    .content_tag = if (cluster.len == 1) .codepoint else .codepoint_grapheme,
                    .style_id = head.style_id,
                    .wide = if (wide) .wide else .narrow,
                },
                .grapheme = remaining[1..cluster.len],
                .style = style,
            });
            if (wide) self.cells.appendAssumeCapacity(.{
                .raw = .{ .wide = .spacer_tail },
                .grapheme = &.{},
                .style = .{},
            });
            remaining = remaining[cluster.len..];
        }
        return self.cells.slice();
    }
};

test "OSC 66 shaping input preserves clusters and clips after the last fitting start" {
    var cells: SizedCells = .{};
    defer cells.deinit(std.testing.allocator);
    const head: terminal.page.Cell = .{ .content = .{ .codepoint = .{ .data = 'f' } } };
    const abc = try cells.build(std.testing.allocator, head, &.{ 'f', 'i', '!' }, .{}, 3);
    try std.testing.expectEqual(3, abc.len);
    try std.testing.expectEqual('f', abc.items(.raw)[1].codepoint());
    try std.testing.expectEqual('i', abc.items(.raw)[2].codepoint());

    const mixed = try cells.build(std.testing.allocator, head, &.{ 0x0301, 0x1f469, 0x200d, 0x1f4bb, '!' }, .{}, 2);
    try std.testing.expectEqual(3, mixed.len);
    try std.testing.expectEqualSlices(u21, &.{0x0301}, mixed.items(.grapheme)[0]);
    try std.testing.expectEqualSlices(u21, &.{ 0x200d, 0x1f4bb }, mixed.items(.grapheme)[1]);
    try std.testing.expectEqual(.spacer_tail, mixed.items(.raw)[2].wide);
}

test {
    _ = Cache;
    _ = Shaper;

    // Always test noop
    _ = noop;
}
