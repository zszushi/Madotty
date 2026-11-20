//! Shader bytecode, resource declarations, and pipeline input layouts for D3D12.
const std = @import("std");
const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const com = @import("com.zig");
const d3d = @import("d3d12.zig");
const dxgi = @import("dxgi.zig");
const log = std.log.scoped(.directx12);

// The CPU-side renderer writes these same layouts for OpenGL and D3D12.
const abi = @import("../opengl/shaders.zig");
pub const Uniforms = abi.Uniforms;
pub const CellText = abi.CellText;
pub const CellBg = abi.CellBg;
pub const Image = abi.Image;
pub const BgImage = abi.BgImage;

// Uniforms.packoffset in shaders.hlsl uses 16-byte HLSL cbuffer registers.
comptime {
    const fields = .{
        .{ "projection_matrix", 0 },
        .{ "screen_size", 64 },
        .{ "cell_size", 72 },
        .{ "grid_size", 80 },
        .{ "grid_padding", 96 },
        .{ "padding_extend", 112 },
        .{ "min_contrast", 116 },
        .{ "cursor_pos", 120 },
        .{ "cursor_color", 124 },
        .{ "bg_color", 128 },
        .{ "bools", 132 },
    };
    for (fields) |field| {
        if (@offsetOf(Uniforms, field[0]) != field[1])
            @compileError("D3D12 uniform offset changed: " ++ field[0]);
    }
    if (@sizeOf(Uniforms) != 144 or @sizeOf(CellBg) != 4)
        @compileError("D3D12 buffer layout changed");
}

fn instanceInput(
    comptime Layout: type,
    comptime field: []const u8,
    semantic: [:0]const u8,
    format: dxgi.DXGI_FORMAT,
) d3d.D3D12_INPUT_ELEMENT_DESC {
    return .{
        .SemanticName = semantic.ptr,
        .SemanticIndex = 0,
        .Format = format,
        .InputSlot = 0,
        .AlignedByteOffset = @offsetOf(Layout, field),
        .InputSlotClass = .PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    };
}

const cell_text_input = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    instanceInput(CellText, "glyph_pos", "GLYPH_POS", .R32G32_UINT),
    instanceInput(CellText, "glyph_size", "GLYPH_SIZE", .R32G32_UINT),
    instanceInput(CellText, "bearings", "BEARINGS", .R16G16_SINT),
    instanceInput(CellText, "grid_pos", "GRID_POS", .R16G16_UINT),
    instanceInput(CellText, "color", "COLOR", .R8G8B8A8_UNORM),
    instanceInput(CellText, "atlas", "ATLAS", .R8_UINT),
    instanceInput(CellText, "bools", "BOOLS", .R8_UINT),
};

const image_input = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    instanceInput(Image, "grid_pos", "GRID_POS", .R32G32_FLOAT),
    instanceInput(Image, "cell_offset", "CELL_OFFSET", .R32G32_FLOAT),
    instanceInput(Image, "source_rect", "SOURCE_RECT", .R32G32B32A32_FLOAT),
    instanceInput(Image, "dest_size", "DEST_SIZE", .R32G32_FLOAT),
};

const bg_image_input = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    instanceInput(BgImage, "opacity", "OPACITY", .R32_FLOAT),
    instanceInput(BgImage, "info", "INFO", .R8_UINT),
};

const full_screen_vs = @embedFile("full_screen_vs");

const Builtin = struct {
    field: []const u8,
    vertex: []const u8,
    pixel: []const u8,
    input: []const d3d.D3D12_INPUT_ELEMENT_DESC = &.{},
    blend: bool = false,
};

const builtins = [_]Builtin{
    .{ .field = "bg_color", .vertex = full_screen_vs, .pixel = @embedFile("bg_color_ps") },
    .{ .field = "cell_bg", .vertex = full_screen_vs, .pixel = @embedFile("cell_bg_ps"), .blend = true },
    .{
        .field = "cell_text",
        .vertex = @embedFile("cell_text_vs"),
        .pixel = @embedFile("cell_text_ps"),
        .input = &cell_text_input,
        .blend = true,
    },
    .{
        .field = "image",
        .vertex = @embedFile("image_vs"),
        .pixel = @embedFile("image_ps"),
        .input = &image_input,
        .blend = true,
    },
    .{
        .field = "bg_image",
        .vertex = @embedFile("bg_image_vs"),
        .pixel = @embedFile("bg_image_ps"),
        .input = &bg_image_input,
    },
};

const Pipelines = struct {
    bg_color: Pipeline,
    cell_bg: Pipeline,
    cell_text: Pipeline,
    image: Pipeline,
    bg_image: Pipeline,
};

pub const Shaders = struct {
    pipelines: Pipelines,
    post_pipelines: []const Pipeline = &.{},
    defunct: bool = false,

    pub const uninit: Shaders = .{ .pipelines = undefined, .defunct = true };

    pub fn init(
        alloc: std.mem.Allocator,
        device: *const Device,
        format: dxgi.DXGI_FORMAT,
        custom: []const [:0]const u8,
    ) !Shaders {
        var result: Shaders = .{ .pipelines = undefined };
        var initialized: usize = 0;
        errdefer inline for (builtins, 0..) |entry, index| {
            if (index < initialized) @field(result.pipelines, entry.field).deinit();
        };

        inline for (builtins) |entry| {
            @field(result.pipelines, entry.field) = try .init(.{
                .device = device,
                .format = format,
                .vertex = entry.vertex,
                .pixel = entry.pixel,
                .input = entry.input,
                .blend = entry.blend,
            });
            initialized += 1;
        }
        result.post_pipelines = try initPostPipelines(alloc, device, format, custom);
        return result;
    }

    pub fn deinit(self: *Shaders, alloc: std.mem.Allocator) void {
        if (self.defunct) return;
        inline for (builtins) |entry| @field(self.pipelines, entry.field).deinit();
        for (self.post_pipelines) |pipeline| pipeline.deinit();
        alloc.free(self.post_pipelines);
        self.* = .uninit;
    }
};

fn initPostPipelines(
    alloc: std.mem.Allocator,
    device: *const Device,
    format: dxgi.DXGI_FORMAT,
    custom: []const [:0]const u8,
) ![]const Pipeline {
    if (custom.len == 0) return &.{};

    const library = d3d.DxcLibrary.load() orelse {
        log.warn("custom shaders need dxcompiler.dll next to the application", .{});
        return &.{};
    };
    defer library.deinit();

    var compiler_ptr: ?*anyopaque = null;
    const hr = library.createInstance(&d3d.CLSID_DxcCompiler, &d3d.IDxcCompiler3.IID, &compiler_ptr);
    if (com.FAILED(hr) or compiler_ptr == null) {
        log.warn("unable to initialize DXC for custom shaders, HRESULT=0x{x}", .{@as(u32, @bitCast(hr))});
        return &.{};
    }
    const compiler: *d3d.IDxcCompiler3 = @ptrCast(@alignCast(compiler_ptr.?));
    defer _ = compiler.Release();

    var pipelines: std.ArrayList(Pipeline) = .empty;
    defer pipelines.deinit(alloc);
    errdefer for (pipelines.items) |pipeline| pipeline.deinit();
    try pipelines.ensureTotalCapacity(alloc, custom.len);

    for (custom) |source| {
        const compiled = compilePostShader(compiler, source) catch |err| {
            log.warn("custom shader compilation failed: {}", .{err});
            continue;
        };
        defer _ = compiled.Release();

        // CreateGraphicsPipelineState copies the bytecode before returning.
        const ptr: [*]const u8 = @ptrCast(compiled.GetBufferPointer());
        const pipeline = Pipeline.init(.{
            .device = device,
            .format = format,
            .vertex = full_screen_vs,
            .pixel = ptr[0..compiled.GetBufferSize()],
        }) catch |err| {
            log.warn("custom shader pipeline creation failed: {}", .{err});
            continue;
        };
        pipelines.appendAssumeCapacity(pipeline);
    }
    return try pipelines.toOwnedSlice(alloc);
}

fn compilePostShader(compiler: *d3d.IDxcCompiler3, source: [:0]const u8) !*d3d.IDxcBlob {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    const args = [_]?[*:0]const u16{ wide("-T"), wide("ps_6_0"), wide("-E"), wide("main"), wide("-O3") };
    const source_buf: d3d.DxcBuffer = .{ .Ptr = source.ptr, .Size = source.len, .Encoding = 65001 };

    var result_ptr: ?*anyopaque = null;
    try com.check("IDxcCompiler3.Compile", compiler.Compile(&source_buf, &args, args.len, null, &d3d.IDxcResult.IID, &result_ptr));
    const result: *d3d.IDxcResult = @ptrCast(@alignCast(result_ptr orelse return error.ShaderCompilationFailed));
    defer _ = result.Release();

    if (com.FAILED(result.GetStatus())) {
        const diagnostics = getOutput(d3d.IDxcBlobUtf8, result, .ERRORS) catch return error.ShaderCompilationFailed;
        defer _ = diagnostics.Release();
        log.warn("DXC: {s}", .{std.mem.span(diagnostics.GetStringPointer())});
        return error.ShaderCompilationFailed;
    }
    return try getOutput(d3d.IDxcBlob, result, .OBJECT);
}

fn getOutput(comptime Blob: type, result: *d3d.IDxcResult, kind: d3d.DXC_OUT_KIND) !*Blob {
    var ptr: ?*anyopaque = null;
    var name: ?*anyopaque = null;
    defer if (name) |name_ptr| {
        const unknown: *com.IUnknown = @ptrCast(@alignCast(name_ptr));
        _ = unknown.vtable.Release(unknown);
    };
    try com.check("IDxcResult.GetOutput", result.GetOutput(kind, &Blob.IID, &ptr, &name));
    return @ptrCast(@alignCast(ptr orelse return error.ShaderCompilationFailed));
}
