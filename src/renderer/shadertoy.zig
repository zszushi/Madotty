const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glslang = @import("glslang");
const spvcross = @import("spirv_cross");
const configpkg = @import("../config.zig");
const shader_parameters = @import("shader_parameters.zig");

const log = std.log.scoped(.shadertoy);

/// The uniform struct used for shadertoy shaders.
pub const Uniforms = extern struct {
    resolution: [3]f32 align(16),
    time: f32 align(4),
    time_delta: f32 align(4),
    frame_rate: f32 align(4),
    frame: i32 align(4),
    channel_time: [4][4]f32 align(16),
    channel_resolution: [4][4]f32 align(16),
    mouse: [4]f32 align(16),
    date: [4]f32 align(16),
    sample_rate: f32 align(4),
    current_cursor: [4]f32 align(16),
    previous_cursor: [4]f32 align(16),
    current_cursor_color: [4]f32 align(16),
    previous_cursor_color: [4]f32 align(16),
    current_cursor_style: i32 align(4),
    previous_cursor_style: i32 align(4),
    cursor_visible: i32 align(4),
    cursor_change_time: f32 align(4),
    time_focus: f32 align(4),
    focus: i32 align(4),
    palette: [256][4]f32 align(16),
    background_color: [4]f32 align(16),
    foreground_color: [4]f32 align(16),
    cursor_color: [4]f32 align(16),
    cursor_text: [4]f32 align(16),
    selection_foreground_color: [4]f32 align(16),
    selection_background_color: [4]f32 align(16),
};

/// The target to load shaders for.
pub const Target = enum { glsl, msl, hlsl, spirv };

/// Load a set of shaders from files and convert them to the target
/// format. The shader order is preserved. SPIR-V is returned as bytes,
/// which can contain zeroes before the trailing sentinel.
pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    target: Target,
    parameter_values: []const [:0]const u8,
) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;
    defer list.deinit(alloc_gpa);
    errdefer for (list.items) |shader| alloc_gpa.free(shader);

    var overrides: std.ArrayList(shader_parameters.Override) = .empty;
    defer overrides.deinit(alloc_gpa);
    for (parameter_values) |value| {
        const parsed = shader_parameters.parseOverride(value) catch {
            log.warn("ignoring invalid custom shader parameter '{s}'", .{value});
            continue;
        };
        try overrides.append(alloc_gpa, parsed);
    }

    for (paths.value.items, 1..) |item, pass| {
        const path, const optional = switch (item) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };

        const shader = loadPass(alloc_gpa, path, target, pass, overrides.items) catch |err| {
            if (err == error.FileNotFound and optional) {
                continue;
            }

            return err;
        };
        log.info("loaded custom shader path={s}", .{path});
        list.append(alloc_gpa, shader) catch |err| {
            alloc_gpa.free(shader);
            return err;
        };
    }

    return try list.toOwnedSlice(alloc_gpa);
}

/// Load a single shader from a file and convert it to the target language
/// ready to be used with renderers.
pub fn loadFromFile(
    alloc_gpa: Allocator,
    path: []const u8,
    target: Target,
) ![:0]const u8 {
    return loadPass(alloc_gpa, path, target, 1, &.{});
}

fn loadPass(
    alloc_gpa: Allocator,
    path: []const u8,
    target: Target,
    pass: usize,
    overrides: []const shader_parameters.Override,
) ![:0]const u8 {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try shader_parameters.readSource(alloc, path);
    const rewritten = shader_parameters.rewrite(alloc, source, pass, overrides) catch |err| switch (err) {
        error.InvalidShaderParameter => blk: {
            log.warn("ignoring custom shader overrides for invalid declarations path={s}", .{path});
            break :blk null;
        },
        else => return err,
    };
    return compileSource(alloc_gpa, alloc, path, rewritten orelse source, target);
}

fn compileSource(alloc_gpa: Allocator, alloc: Allocator, path: []const u8, src: []const u8, target: Target) ![:0]const u8 {
    // Convert to full GLSL
    const glsl: [:0]const u8 = glsl: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        try writeGlslSource(&stream.writer, src, target);
        try stream.writer.writeByte(0);
        break :glsl stream.written()[0 .. stream.written().len - 1 :0];
    };

    // Convert to SPIR-V
    const spirv: []align(@alignOf(u32)) const u8 = spirv: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        var errlog: SpirvLog = .{ .alloc = alloc };
        defer errlog.deinit();
        spirvFromGlsl(&stream.writer, &errlog, glsl) catch |err| {
            if (errlog.info.len > 0 or errlog.debug.len > 0) {
                log.warn("spirv error path={s} info={s} debug={s}", .{
                    path,
                    errlog.info,
                    errlog.debug,
                });
            }

            return err;
        };

        // SpirV pointer must be aligned to 4 bytes since we expect
        // a slice of words.
        var list: std.ArrayListAligned(u8, .of(u32)) = .empty;
        try list.appendSlice(alloc, stream.written());
        break :spirv list.items;
    };

    // Convert to the renderer's shader language.
    return switch (target) {
        // Important: using the alloc_gpa here on purpose because this
        // is the final result that will be returned to the caller.
        .glsl => try glslFromSpv(alloc_gpa, spirv),
        .msl => try mslFromSpv(alloc_gpa, spirv),
        .hlsl => try hlslFromSpv(alloc_gpa, spirv),
        .spirv => blk: {
            validateVulkanSpirv(spirv) catch |err| {
                log.warn("Vulkan custom shader interface does not match the postprocess pipeline path={s} err={t}", .{ path, err });
                return err;
            };
            break :blk try alloc_gpa.dupeSentinel(u8, spirv, 0);
        },
    };
}

/// Convert a ShaderToy shader into valid GLSL.
///
/// ShaderToy shaders aren't full shaders, they're just implementing a
/// mainImage function and don't define any of the uniforms. This function
/// will convert the ShaderToy shader into a valid GLSL shader that can be
/// compiled and linked.
pub fn glslFromShader(writer: *std.Io.Writer, src: []const u8) !void {
    return writeGlslSource(writer, src, .glsl);
}

fn writeGlslSource(writer: *std.Io.Writer, src: []const u8, target: Target) !void {
    try writer.writeAll("#version 430 core\n");
    switch (target) {
        .glsl, .msl => {},
        // Keep the builtin coordinate for SV_Position and Vulkan FragCoord.
        .hlsl => try writer.writeAll("#define GHOSTTY_NATIVE_FRAG_COORD\n"),
        .spirv => try writer.writeAll(
            "#define GHOSTTY_NATIVE_FRAG_COORD\n#define GHOSTTY_VULKAN_POSTPROCESS\n",
        ),
    }
    try writer.writeAll(@embedFile("shaders/shadertoy_prefix.glsl"));
    try writer.writeAll("\n\n");
    try writer.writeAll(src);
}

/// Vulkan pipes the compiled fragment module directly into a fixed pipeline.
/// Restrict its active interface to the resources that pipeline supplies.
fn validateVulkanSpirv(spirv: []align(@alignOf(u32)) const u8) !void {
    const c = spvcross.c;
    var ctx: c.spvc_context = undefined;
    if (c.spvc_context_create(&ctx) != c.SPVC_SUCCESS) return error.SpvcFailed;
    defer c.spvc_context_destroy(ctx);

    var ir: c.spvc_parsed_ir = undefined;
    if (c.spvc_context_parse_spirv(ctx, @ptrCast(spirv.ptr), spirv.len / @sizeOf(u32), &ir) != c.SPVC_SUCCESS)
        return error.SpvcFailed;
    var compiler: c.spvc_compiler = undefined;
    if (c.spvc_context_create_compiler(ctx, c.SPVC_BACKEND_NONE, ir, c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler) != c.SPVC_SUCCESS)
        return error.SpvcFailed;
    var modes: [*c]const c.SpvExecutionMode = undefined;
    var mode_count: usize = undefined;
    if (c.spvc_compiler_get_execution_modes(compiler, &modes, &mode_count) != c.SPVC_SUCCESS)
        return error.SpvcFailed;
    if (c.spvc_compiler_get_execution_model(compiler) != c.SpvExecutionModelFragment or
        std.mem.indexOfScalar(c.SpvExecutionMode, modes[0..mode_count], c.SpvExecutionModeOriginUpperLeft) == null)
        return error.InvalidVulkanShaderInterface;
    var active: c.spvc_set = undefined;
    if (c.spvc_compiler_get_active_interface_variables(compiler, &active) != c.SPVC_SUCCESS)
        return error.SpvcFailed;
    var resources: c.spvc_resources = undefined;
    if (c.spvc_compiler_create_shader_resources_for_active_variables(compiler, &resources, active) != c.SPVC_SUCCESS)
        return error.SpvcFailed;

    var entries: [*c]const c.spvc_reflected_resource = undefined;
    var count: usize = undefined;
    for ([_]c.spvc_resource_type{
        c.SPVC_RESOURCE_TYPE_UNIFORM_BUFFER,
        c.SPVC_RESOURCE_TYPE_SAMPLED_IMAGE,
        c.SPVC_RESOURCE_TYPE_STAGE_INPUT,
        c.SPVC_RESOURCE_TYPE_STAGE_OUTPUT,
        c.SPVC_RESOURCE_TYPE_STORAGE_BUFFER,
        c.SPVC_RESOURCE_TYPE_SUBPASS_INPUT,
        c.SPVC_RESOURCE_TYPE_STORAGE_IMAGE,
        c.SPVC_RESOURCE_TYPE_ATOMIC_COUNTER,
        c.SPVC_RESOURCE_TYPE_PUSH_CONSTANT,
        c.SPVC_RESOURCE_TYPE_SEPARATE_IMAGE,
        c.SPVC_RESOURCE_TYPE_SEPARATE_SAMPLERS,
        c.SPVC_RESOURCE_TYPE_ACCELERATION_STRUCTURE,
        c.SPVC_RESOURCE_TYPE_SHADER_RECORD_BUFFER,
    }) |kind| {
        if (c.spvc_resources_get_resource_list_for_type(resources, kind, &entries, &count) != c.SPVC_SUCCESS)
            return error.SpvcFailed;
        if (count == 0) continue;
        if (count > 1) return error.InvalidVulkanShaderInterface;
        const resource = entries[0];
        switch (kind) {
            c.SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, c.SPVC_RESOURCE_TYPE_SAMPLED_IMAGE => {
                const globals = kind == c.SPVC_RESOURCE_TYPE_UNIFORM_BUFFER;
                const id = if (globals) resource.base_type_id else resource.id;
                const name = std.mem.span(c.spvc_compiler_get_name(compiler, id));
                if (!std.mem.eql(u8, name, if (globals) "Globals" else "iChannel0") or
                    c.spvc_compiler_get_decoration(compiler, resource.id, c.SpvDecorationDescriptorSet) != 0 or
                    c.spvc_compiler_get_decoration(compiler, resource.id, c.SpvDecorationBinding) != @intFromBool(!globals))
                    return error.InvalidVulkanShaderInterface;
            },
            c.SPVC_RESOURCE_TYPE_STAGE_OUTPUT => {
                if (c.spvc_compiler_get_decoration(compiler, resource.id, c.SpvDecorationLocation) != 0)
                    return error.InvalidVulkanShaderInterface;
            },
            else => return error.InvalidVulkanShaderInterface,
        }
    }
}

/// Convert a GLSL shader into SPIR-V assembly.
pub fn spirvFromGlsl(
    writer: *std.Io.Writer,
    errlog: ?*SpirvLog,
    src: [:0]const u8,
) !void {
    // So we can run unit tests without fear.
    if (builtin.is_test) try glslang.testing.ensureInit();

    const c = glslang.c;
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = c.GLSLANG_STAGE_FRAGMENT,
        .client = c.GLSLANG_CLIENT_VULKAN,
        .client_version = c.GLSLANG_TARGET_VULKAN_1_2,
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = c.GLSLANG_TARGET_SPV_1_5,
        .code = src.ptr,
        .default_version = 100,
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = c.GLSLANG_MSG_DEFAULT_BIT,
        .resource = c.glslang_default_resource(),
    };

    const shader = try glslang.Shader.create(&input);
    defer shader.delete();

    shader.preprocess(&input) catch |err| {
        if (errlog) |ptr| ptr.fromShader(shader) catch {};
        return err;
    };
    shader.parse(&input) catch |err| {
        if (errlog) |ptr| ptr.fromShader(shader) catch {};
        return err;
    };

    const program = try glslang.Program.create();
    defer program.delete();
    program.addShader(shader);
    program.link(
        c.GLSLANG_MSG_SPV_RULES_BIT |
            c.GLSLANG_MSG_VULKAN_RULES_BIT,
    ) catch |err| {
        if (errlog) |ptr| ptr.fromProgram(program) catch {};
        return err;
    };
    program.spirvGenerate(c.GLSLANG_STAGE_FRAGMENT);
    const size = program.spirvGetSize();
    const ptr = try program.spirvGetPtr();
    const ptr_u8: [*]u8 = @ptrCast(ptr);
    const slice_u8: []u8 = ptr_u8[0 .. size * 4];
    try writer.writeAll(slice_u8);
}

/// Retrieve errors from spirv compilation.
pub const SpirvLog = struct {
    alloc: Allocator,
    info: [:0]const u8 = "",
    debug: [:0]const u8 = "",

    pub fn deinit(self: *const SpirvLog) void {
        if (self.info.len > 0) self.alloc.free(self.info);
        if (self.debug.len > 0) self.alloc.free(self.debug);
    }

    fn fromShader(self: *SpirvLog, shader: *glslang.Shader) !void {
        const info = try shader.getInfoLog();
        const debug = try shader.getDebugInfoLog();
        self.info = "";
        self.debug = "";
        if (info.len > 0) self.info = try self.alloc.dupeSentinel(u8, info, 0);
        if (debug.len > 0) self.debug = try self.alloc.dupeSentinel(u8, debug, 0);
    }

    fn fromProgram(self: *SpirvLog, program: *glslang.Program) !void {
        const info = try program.getInfoLog();
        const debug = try program.getDebugInfoLog();
        self.info = "";
        self.debug = "";
        if (info.len > 0) self.info = try self.alloc.dupeSentinel(u8, info, 0);
        if (debug.len > 0) self.debug = try self.alloc.dupeSentinel(u8, debug, 0);
    }
};

/// Convert SPIR-V binary to MSL.
pub fn mslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const c = spvcross.c;
    return try spvCross(alloc, spvcross.c.SPVC_BACKEND_MSL, spv, (struct {
        fn setOptions(_: c.spvc_compiler, options: c.spvc_compiler_options) error{SpvcFailed}!void {
            // We enable decoration binding, because we need this
            // to properly locate the uniform block to index 1.
            if (c.spvc_compiler_options_set_bool(
                options,
                c.SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING,
                c.SPVC_TRUE,
            ) != c.SPVC_SUCCESS) {
                return error.SpvcFailed;
            }
        }
    }).setOptions);
}

/// Convert SPIR-V binary to GLSL.
pub fn glslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const GLSL_VERSION = 430;

    const c = spvcross.c;
    return try spvCross(alloc, c.SPVC_BACKEND_GLSL, spv, (struct {
        fn setOptions(_: c.spvc_compiler, options: c.spvc_compiler_options) error{SpvcFailed}!void {
            if (c.spvc_compiler_options_set_uint(
                options,
                c.SPVC_COMPILER_OPTION_GLSL_VERSION,
                GLSL_VERSION,
            ) != c.SPVC_SUCCESS) {
                return error.SpvcFailed;
            }
        }
    }).setOptions);
}

/// Convert SPIR-V binary to HLSL for the D3D12 postprocess pipeline.
pub fn hlslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const c = spvcross.c;
    return spvCross(alloc, c.SPVC_BACKEND_HLSL, spv, (struct {
        fn setOptions(compiler: c.spvc_compiler, options: c.spvc_compiler_options) error{SpvcFailed}!void {
            if (c.spvc_compiler_options_set_uint(
                options,
                c.SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL,
                60,
            ) != c.SPVC_SUCCESS) return error.SpvcFailed;

            // The shared GLSL prefix declares Globals at binding 1 and
            // iChannel0 at binding 0. D3D12 uses b0, t0 and s0.
            var globals: c.spvc_hlsl_resource_binding = undefined;
            c.spvc_hlsl_resource_binding_init(&globals);
            globals.stage = c.SpvExecutionModelFragment;
            globals.desc_set = 0;
            globals.binding = 1;
            globals.cbv = .{ .register_space = 0, .register_binding = 0 };
            if (c.spvc_compiler_hlsl_add_resource_binding(compiler, &globals) != c.SPVC_SUCCESS)
                return error.SpvcFailed;
        }
    }).setOptions);
}

fn spvCross(
    alloc: Allocator,
    backend: spvcross.c.spvc_backend,
    spv: []const u8,
    comptime optionsFn_: ?*const fn (spvcross.c.spvc_compiler, spvcross.c.spvc_compiler_options) error{SpvcFailed}!void,
) ![:0]const u8 {
    // Spir-V is always a multiple of 4 because it is written as a series of words
    if (@mod(spv.len, 4) != 0) return error.SpirvInvalid;

    // Compiler context
    const c = spvcross.c;
    var ctx: c.spvc_context = undefined;
    if (c.spvc_context_create(&ctx) != c.SPVC_SUCCESS) return error.SpvcFailed;
    defer c.spvc_context_destroy(ctx);

    // It would be better to get this out into an output parameter to
    // show users but for now we can just log it.
    c.spvc_context_set_error_callback(ctx, @ptrCast(&(struct {
        fn callback(_: ?*anyopaque, msg_ptr: [*c]const u8) callconv(.c) void {
            const msg = std.mem.sliceTo(msg_ptr, 0);
            std.log.warn("spirv-cross error message={s}", .{msg});
        }
    }).callback), null);

    // Parse the Spir-V binary to an IR
    var ir: c.spvc_parsed_ir = undefined;
    if (c.spvc_context_parse_spirv(
        ctx,
        @ptrCast(@alignCast(spv.ptr)),
        spv.len / 4,
        &ir,
    ) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    // Build our compiler to GLSL
    var compiler: c.spvc_compiler = undefined;
    if (c.spvc_context_create_compiler(
        ctx,
        backend,
        ir,
        c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    ) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    // Setup our options if we have any
    if (optionsFn_) |optionsFn| {
        var options: c.spvc_compiler_options = undefined;
        if (c.spvc_compiler_create_compiler_options(compiler, &options) != c.SPVC_SUCCESS) {
            return error.SpvcFailed;
        }

        try optionsFn(compiler, options);

        if (c.spvc_compiler_install_compiler_options(compiler, options) != c.SPVC_SUCCESS) {
            return error.SpvcFailed;
        }
    }

    // Compile the resulting string. This string pointer is owned by the
    // context so we don't need to free it.
    var result: [*:0]const u8 = undefined;
    if (c.spvc_compiler_compile(compiler, @ptrCast(&result)) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    return try alloc.dupeSentinel(u8, std.mem.sliceTo(result, 0), 0);
}

/// Convert ShaderToy shader to null-terminated glsl for testing.
fn testGlslZ(alloc: Allocator, src: []const u8) ![:0]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try glslFromShader(&buf.writer, src);
    return try buf.toOwnedSliceSentinel(0);
}

test "custom shader selection uniform layout matches compiled GLSL" {
    const testing = std.testing;
    const c = spvcross.c;
    const src = try testGlslZ(testing.allocator,
        \\void mainImage(out vec4 color, in vec2 pixel) {
        \\    color = vec4(iSelectionForegroundColor + iSelectionBackgroundColor, 1.0);
        \\}
    );
    defer testing.allocator.free(src);

    var buf: [4096 * 4]u8 align(4) = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try spirvFromGlsl(&writer, null, src);

    var ctx: c.spvc_context = undefined;
    try testing.expectEqual(c.SPVC_SUCCESS, c.spvc_context_create(&ctx));
    defer c.spvc_context_destroy(ctx);
    var ir: c.spvc_parsed_ir = undefined;
    try testing.expectEqual(c.SPVC_SUCCESS, c.spvc_context_parse_spirv(
        ctx,
        @ptrCast(&buf),
        writer.buffered().len / 4,
        &ir,
    ));
    var compiler: c.spvc_compiler = undefined;
    try testing.expectEqual(c.SPVC_SUCCESS, c.spvc_context_create_compiler(
        ctx,
        c.SPVC_BACKEND_NONE,
        ir,
        c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    ));
    var resources: c.spvc_resources = undefined;
    try testing.expectEqual(c.SPVC_SUCCESS, c.spvc_compiler_create_shader_resources(compiler, &resources));
    var blocks: [*c]const c.spvc_reflected_resource = undefined;
    var count: usize = 0;
    try testing.expectEqual(c.SPVC_SUCCESS, c.spvc_resources_get_resource_list_for_type(
        resources,
        c.SPVC_RESOURCE_TYPE_UNIFORM_BUFFER,
        &blocks,
        &count,
    ));
    try testing.expectEqual(@as(usize, 1), count);
    const id = blocks[0].base_type_id;
    const typ = c.spvc_compiler_get_type_handle(compiler, id);

    inline for (.{
        .{ "selection_foreground_color", "iSelectionForegroundColor" },
        .{ "selection_background_color", "iSelectionBackgroundColor" },
    }) |field| {
        var found = false;
        for (0..c.spvc_type_get_num_member_types(typ)) |i| {
            const index: c_uint = @intCast(i);
            const name = std.mem.span(c.spvc_compiler_get_member_name(compiler, id, index));
            if (!std.mem.eql(u8, field[1], name)) continue;
            var offset: c_uint = 0;
            try testing.expectEqual(c.SPVC_SUCCESS, c.spvc_compiler_type_struct_member_offset(compiler, typ, index, &offset));
            try testing.expectEqual(@offsetOf(Uniforms, field[0]), offset);
            found = true;
            break;
        }
        try testing.expect(found);
    }
}

test "spirv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: [4096 * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try spirvFromGlsl(&writer, null, src);
}

test "spirv invalid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_invalid);
    defer alloc.free(src);

    var buf: [4096 * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var errlog: SpirvLog = .{ .alloc = alloc };
    defer errlog.deinit();
    try testing.expectError(error.GlslangFailed, spirvFromGlsl(&writer, &errlog, src));
    try testing.expect(errlog.info.len > 0);
}

test "shadertoy to msl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try spirvFromGlsl(&buf.writer, null, src);

    // TODO: Replace this with an aligned version of Writer.Allocating
    var spvlist: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer spvlist.deinit(alloc);
    try spvlist.appendSlice(alloc, buf.written());

    const msl = try mslFromSpv(alloc, spvlist.items);
    defer alloc.free(msl);
}

test "shadertoy to glsl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try spirvFromGlsl(&buf.writer, null, src);

    // TODO: Replace this with an aligned version of Writer.Allocating
    var spvlist: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer spvlist.deinit(alloc);
    try spvlist.appendSlice(alloc, buf.written());

    const glsl = try glslFromSpv(alloc, spvlist.items);
    defer alloc.free(glsl);

    // log.warn("glsl={s}", .{glsl});
}

test "shadertoy to hlsl uses Direct3D bindings and pixel coordinates" {
    if (@import("../build_config.zig").renderer != .d3d12) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    var glsl: std.Io.Writer.Allocating = .init(alloc);
    defer glsl.deinit();
    try writeGlslSource(&glsl.writer, test_crt, .hlsl);
    const source = try glsl.toOwnedSliceSentinel(0);
    defer alloc.free(source);

    var buf: [4096 * 4]u8 align(4) = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try spirvFromGlsl(&writer, null, source);

    const hlsl = try hlslFromSpv(alloc, writer.buffered());
    defer alloc.free(hlsl);
    for ([_][]const u8{ "register(b0, space0)", "register(t0, space0)", "register(s0, space0)", "SV_Position" }) |binding| {
        try testing.expect(std.mem.indexOf(u8, hlsl, binding) != null);
    }
}

test "shadertoy to spirv uses Vulkan bindings and native pixel coordinates" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();

    const binary = try compileSource(alloc, arena.allocator(), "crt.glsl", test_crt, .spirv);
    defer alloc.free(binary);
    try testing.expect(binary.len > 20 and binary.len % @sizeOf(u32) == 0);
    try testing.expectEqual(@as(u32, 0x07230203), std.mem.readInt(u32, binary[0..4], .little));
    try testing.expect(std.mem.indexOfScalar(u8, binary, 0) != null);
    try testing.expectEqual(@as(u8, 0), binary[binary.len]);

    const extra_sampler =
        \\layout(set = 1, binding = 0) uniform sampler2D source;
        \\void mainImage(out vec4 color, in vec2 pixel) {
        \\    color = texture(source, pixel / iResolution.xy);
        \\}
    ;
    try testing.expectError(error.InvalidVulkanShaderInterface, compileSource(
        alloc,
        arena.allocator(),
        "extra-sampler.glsl",
        extra_sampler,
        .spirv,
    ));
}

test "custom shader parameters reach GLSL and HLSL compilation" {
    const alloc = std.testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const source =
        \\#pragma parameter GAIN "Gain" 0.25 0 1 0.05
        \\const float GAIN = 0.25;
        \\void mainImage(out vec4 color, in vec2 point) { color = vec4(GAIN, 0.0, 0.0, 1.0); }
    ;
    const overrides = [_]shader_parameters.Override{try shader_parameters.parseOverride("1:GAIN:0.75")};
    const tuned = (try shader_parameters.rewrite(arena.allocator(), source, 1, &overrides)).?;
    const targets: []const Target = if (@import("../build_config.zig").renderer == .d3d12) &.{ .glsl, .hlsl } else &.{.glsl};
    for (targets) |target| {
        const original = try compileSource(alloc, arena.allocator(), "test.glsl", source, target);
        defer alloc.free(original);
        const compiled = try compileSource(alloc, arena.allocator(), "test.glsl", tuned, target);
        defer alloc.free(compiled);
        try std.testing.expect(std.mem.indexOf(u8, original, "0.25") != null);
        try std.testing.expect(std.mem.indexOf(u8, compiled, "0.75") != null);
    }
}

const test_crt = @embedFile("shaders/test_shadertoy_crt.glsl");
const test_invalid = @embedFile("shaders/test_shadertoy_invalid.glsl");
const test_focus = @embedFile("shaders/test_shadertoy_focus.glsl");
