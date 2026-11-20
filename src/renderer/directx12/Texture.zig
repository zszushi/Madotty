//! Texture storage shared by glyphs, images and offscreen render targets.
const Texture = @This();
const std = @import("std");
const com = @import("com.zig");
const d3d = @import("d3d12.zig");
const dxgi = @import("dxgi.zig");
const Context = @import("Context.zig");

pub const Error = anyerror;
pub const Options = struct {
    context: *Context,
    format: dxgi.DXGI_FORMAT,
    resource_format: ?dxgi.DXGI_FORMAT = null,
    render_target: bool = false,
};

context: *Context,
format: dxgi.DXGI_FORMAT,
resource: *d3d.ID3D12Resource,
width: usize,
height: usize,

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Texture {
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidTextureExtent;
    const resource = try Context.createResource(opts.context.device, .DEFAULT, &.{
        .Dimension = .TEXTURE2D,
        .Alignment = 0,
        .Width = width,
        .Height = @intCast(height),
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = opts.resource_format orelse opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Layout = .UNKNOWN,
        .Flags = if (opts.render_target) .ALLOW_RENDER_TARGET else .NONE,
    }, Context.texture_state);
    errdefer _ = resource.Release();
    const result: Texture = .{ .context = opts.context, .format = opts.format, .resource = resource, .width = width, .height = height };
    if (data) |bytes| try result.replaceRegion(0, 0, width, height, bytes);
    return result;
}

pub fn deinit(self: Texture) void {
    _ = self.resource.Release();
}

pub fn replaceRegion(self: Texture, x: usize, y: usize, width: usize, height: usize, data: []const u8) Error!void {
    if (x > self.width or y > self.height or width > self.width - x or height > self.height - y) return error.InvalidTextureExtent;
    if (width == 0 or height == 0) return;
    const bytes_per_pixel: usize = if (self.format == .R8_UNORM) 1 else 4;
    const row_size = width * bytes_per_pixel;
    if (data.len < row_size * height) return error.InvalidTextureData;
    const row_pitch = std.mem.alignForward(usize, row_size, 256);
    const staging = try Context.uploadBuffer(self.context.device, row_pitch * height);
    defer _ = staging.Release();
    var address: ?*anyopaque = null;
    try com.check("Map texture staging buffer", staging.Map(0, &.{ .Begin = 0, .End = 0 }, &address));
    const out: [*]u8 = @ptrCast(address.?);
    for (0..height) |row| {
        @memcpy(out[row * row_pitch ..][0..row_size], data[row * row_size ..][0..row_size]);
    }
    staging.Unmap(0, null);

    const src: d3d.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = staging,
        .Type = .PLACED_FOOTPRINT,
        .u = .{ .PlacedFootprint = .{
            .Offset = 0,
            .Footprint = .{
                .Format = self.format,
                .Width = @intCast(width),
                .Height = @intCast(height),
                .Depth = 1,
                .RowPitch = @intCast(row_pitch),
            },
        } },
    };
    const dst: d3d.D3D12_TEXTURE_COPY_LOCATION = .{ .pResource = self.resource, .Type = .SUBRESOURCE_INDEX, .u = .{ .SubresourceIndex = 0 } };
    const commands = try self.context.beginTransfer(staging, self.resource);
    Context.transitionOn(commands, self.resource, Context.texture_state, .COPY_DEST);
    commands.CopyTextureRegion(&dst, @intCast(x), @intCast(y), 0, &src, null);
    Context.transitionOn(commands, self.resource, .COPY_DEST, Context.texture_state);
    try self.context.executeTransfer();
}
