//! Shader data exchanged with the settings window.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const global = @import("../../global.zig");
const params = @import("../../renderer/shader_parameters.zig");
const Allocator = std.mem.Allocator;

pub const Parameter = params.Parameter;
pub const Override = params.Override;

pub const Path = struct {
    path: []const u8,
    optional: bool = false,

    fn fromConfig(path: Config.Path) Path {
        return switch (path) {
            .required => |value| .{ .path = value },
            .optional => |value| .{ .path = value, .optional = true },
        };
    }

    fn matches(self: Path, other: Path) bool {
        return self.optional == other.optional and std.mem.eql(u8, self.path, other.path);
    }
};

const ParameterValue = struct {
    pass: usize,
    name: []const u8,
    label: []const u8,
    default: f64,
    min: f64,
    max: f64,
    step: f64,
    integer: bool,
    value: f64,
};

pub const Snapshot = struct {
    items: []const Path,
    animation: Config.CustomShaderAnimation,
    parameters: []const ParameterValue,
    overrides: []const Override,
};

pub fn snapshot(alloc: Allocator, config: *const Config) !Snapshot {
    const paths = config.@"custom-shader".value.items;
    const items = try alloc.alloc(Path, paths.len);
    var overrides: std.ArrayList(Override) = .empty;
    for (config.@"custom-shader-parameter".list.items) |text| {
        try overrides.append(alloc, params.parseOverride(text) catch continue);
    }

    var parameters: std.ArrayList(ParameterValue) = .empty;
    for (paths, items, 1..) |path, *item, pass| {
        item.* = .fromConfig(path);
        const declarations = params.inspectFile(alloc, item.path) catch continue;
        for (declarations) |decl| {
            var value = decl.default;
            for (overrides.items) |override| {
                if (override.pass == pass and std.mem.eql(u8, override.name, decl.name) and decl.accepts(override.value))
                    value = override.value;
            }
            try parameters.append(alloc, .{
                .pass = pass,
                .name = decl.name,
                .label = decl.label,
                .default = decl.default,
                .min = decl.min,
                .max = decl.max,
                .step = decl.step,
                .integer = decl.integer,
                .value = value,
            });
        }
    }
    return .{
        .items = items,
        .animation = config.@"custom-shader-animation",
        .parameters = parameters.items,
        .overrides = overrides.items,
    };
}

pub fn inspect(alloc: Allocator, path: []const u8) ![]const Parameter {
    try validatePath(path);
    return params.inspectFile(alloc, path);
}

fn validatePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\x00\r\n\"") != null)
        return error.InvalidShaderPath;
}

pub fn validate(alloc: Allocator, config: *const Config, paths: ?[]const Path, overrides: ?[]const Override) !void {
    const originals = config.@"custom-shader".value.items;
    if (paths) |items| for (items) |item| {
        try validatePath(item.path);
        if (item.optional) continue;
        for (originals) |original| {
            if (item.matches(.fromConfig(original))) break;
        } else std.Io.Dir.cwd().access(global.io(), item.path, .{}) catch return error.ShaderFileUnavailable;
    };

    const changed = overrides orelse return;
    const count = if (paths) |items| items.len else originals.len;
    const declarations = try alloc.alloc(?[]const Parameter, count);
    @memset(declarations, null);
    for (changed) |value| {
        if (value.pass == 0 or !std.math.isFinite(value.value)) return error.InvalidShaderParameter;
        const index = value.pass - 1;
        // Previously saved values can be kept when a shader is temporarily
        // missing or its author has changed a parameter's range, even if the
        // user moved that pass or changed whether its path is optional.
        const current: ?Path = if (index >= count) null else if (paths) |items| items[index] else .fromConfig(originals[index]);
        if (wasConfigured(config, current, value)) continue;
        const path = (current orelse return error.InvalidShaderParameter).path;
        try validateParameter(alloc, path, &declarations[index], value);
    }
}

fn wasConfigured(config: *const Config, path: ?Path, value: Override) bool {
    const originals = config.@"custom-shader".value.items;
    for (config.@"custom-shader-parameter".list.items) |text| {
        const prior = params.parseOverride(text) catch continue;
        if (prior.value != value.value or !std.mem.eql(u8, prior.name, value.name)) continue;
        if (path) |current| {
            if (prior.pass <= originals.len and std.mem.eql(u8, Path.fromConfig(originals[prior.pass - 1]).path, current.path)) return true;
        } else if (prior.pass > originals.len and prior.pass == value.pass) return true;
    }
    return false;
}

fn validateParameter(alloc: Allocator, path: []const u8, declarations: *?[]const Parameter, value: Override) !void {
    if (declarations.* == null) declarations.* = inspect(alloc, path) catch return error.InvalidShaderParameter;
    for (declarations.*.?) |decl| {
        if (std.mem.eql(u8, decl.name, value.name) and decl.accepts(value.value)) return;
    }
    return error.InvalidShaderParameter;
}

fn equalOverride(a: Override, b: Override) bool {
    return a.pass == b.pass and std.mem.eql(u8, a.name, b.name) and a.value == b.value;
}

pub fn editsApplied(config: *const Config, paths: ?[]const Path, overrides: ?[]const Override) bool {
    if (paths) |items| {
        const actual = config.@"custom-shader".value.items;
        if (actual.len != items.len) return false;
        for (actual, items) |entry, item| {
            if (!item.matches(.fromConfig(entry))) return false;
        }
    }
    if (overrides) |items| {
        const actual = config.@"custom-shader-parameter".list.items;
        if (actual.len != items.len) return false;
        for (actual, items) |text, item| {
            if (!equalOverride(params.parseOverride(text) catch return false, item)) return false;
        }
    }
    return true;
}
