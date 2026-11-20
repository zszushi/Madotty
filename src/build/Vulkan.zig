const std = @import("std");
const translate_c = @import("translate_c");
const Config = @import("Config.zig");
const shaders = @import("../renderer/vulkan/shaders.zig");

pub fn addSmoke(b: *std.Build, config: *const Config) !void {
    const step = b.step("vulkan-smoke", "Build the Win32 Vulkan presentation test");
    const module = b.createModule(.{
        .root_source_file = b.path("src/vulkan_smoke.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    if (!try addImports(b, module, config)) return;
    module.linkSystemLibrary("user32", .{});
    const exe = b.addExecutable(.{
        .name = "madotty-vulkan-smoke",
        .root_module = module,
        .use_llvm = true,
    });
    exe.subsystem = .console;
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}

pub fn addImports(b: *std.Build, module: *std.Build.Module, config: *const Config) !bool {
    const headers = b.lazyDependency("vulkan_headers", .{}) orelse return false;
    try translate_c.addImportToModule(b, "vulkan_c", module, .{
        .source = .{ .file = b.path("src/renderer/vulkan/win32_vulkan.h") },
        .target = config.target,
        .optimize = config.optimize,
        .include_paths = &.{headers.path("Vulkan-Headers-1.3.296/include")},
        .default_init = true,
    });

    const dxc: std.Build.LazyPath = if (config.dxc) |path|
        .{ .cwd_relative = path }
    else
        b.findProgramLazy(.{ .names = &.{"dxc"} });
    const source = b.path(shaders.source_path);
    inline for (std.enums.values(shaders.Entry)) |entry| {
        const name = @tagName(entry);
        const run = std.Build.Step.Run.create(b, b.fmt("compile Vulkan shader {s}", .{name}));
        run.addFileArg(dxc);
        run.addArgs(shaders.spirv_args);
        run.addArgs(&.{ "-T", entry.profile(), "-E", name, "-O3", "-Ges" });
        if (entry.stage() == .vertex) run.addArg("-fvk-invert-y");
        run.addArg("-Fo");
        const spirv = run.addOutputFileArg(b.fmt("{s}.spv", .{name}));
        run.addFileArg(source);
        module.addAnonymousImport(entry.embedName(), .{ .root_source_file = spirv });
    }
    return true;
}
