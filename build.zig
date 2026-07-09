const std = @import("std");
const sk = @import("sokol");

pub const EmLinkOptions = sk.EmLinkOptions;

pub const defaultEmLinkOptions: EmLinkOptions = .{
    .target = undefined,
    .optimize = undefined,
    .lib_main = undefined,
    .emsdk = undefined,
    .shell_file_path = null,
};

pub const App = struct {
    module: *std.Build.Module,
    artifact: *std.Build.Step.Compile,
};

pub const AppOption = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zhuyu: *std.Build.Dependency,
    imports: []const std.Build.Module.Import = &.{},
    em_link: EmLinkOptions = defaultEmLinkOptions,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokolModule = sokol.module("sokol");
    const shader = try createShader(b, sokol, sokolModule);

    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);

    const stb = b.dependency("stb", .{
        .target = target,
        .optimize = optimize,
    });
    zhu.addIncludePath(stb.path("."));
    if (target.result.os.tag == .emscripten) {
        const emsdk = sokol.builder.dependency("emsdk", .{});
        zhu.addSystemIncludePath(emsdk.path(b.pathJoin(&.{
            "upstream",
            "emscripten",
            "cache",
            "sysroot",
            "include",
        })));
    }
    zhu.addCSourceFile(.{
        .file = b.path("src/internal/stb_audio.c"),
        .flags = if (target.result.os.tag == .emscripten)
            &.{ "-O2", "-fno-sanitize=undefined" }
        else
            &.{"-O2"},
    });

    const tests = b.addTest(.{ .root_module = zhu });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

// 添加一个使用 ZhuYu 的应用目标。
pub fn addApp(b: *std.Build, options: AppOption) !App {
    const mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = options.imports,
    });

    if (!options.target.result.cpu.arch.isWasm()) {
        return addNativeApp(b, options, mod);
    }

    return try addWebApp(b, options, mod);
}

fn addNativeApp(
    b: *std.Build,
    options: AppOption,
    mod: *std.Build.Module,
) App {
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = mod,
    });
    if (options.optimize != .Debug) exe.subsystem = .Windows;

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the app").dependOn(&run.step);

    return .{ .module = mod, .artifact = exe };
}

fn addWebApp(
    b: *std.Build,
    options: AppOption,
    mod: *std.Build.Module,
) !App {
    const sokol = options.zhuyu.builder.dependency("sokol", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const emsdk = sokol.builder.dependency("emsdk", .{});
    const emsdkStep = sk.emSdkInstallStep(b, emsdk, .{});
    b.step("install-emsdk", "install emsdk").dependOn(emsdkStep);

    const lib = b.addLibrary(.{
        .name = options.name,
        .root_module = mod,
    });

    var emLink = options.em_link;
    emLink.target = options.target;
    emLink.optimize = options.optimize;
    emLink.lib_main = lib;
    emLink.emsdk = emsdk;

    const extraArgs = try b.allocator.alloc(
        []const u8,
        emLink.extra_args.len + 4,
    );
    @memcpy(extraArgs[0..emLink.extra_args.len], emLink.extra_args);
    extraArgs[emLink.extra_args.len + 0] = "--js-library";
    extraArgs[emLink.extra_args.len + 1] =
        options.zhuyu.path("src/internal/em.js").getPath(b);
    extraArgs[emLink.extra_args.len + 2] = "--pre-js";
    extraArgs[emLink.extra_args.len + 3] = try emJsCacheStamp(b);
    emLink.extra_args = extraArgs;

    const linkStep = try sk.emLinkStep(b, emLink);
    b.getInstallStep().dependOn(&linkStep.step);

    return .{ .module = mod, .artifact = lib };
}

fn createShader(
    b: *std.Build,
    sokol: *std.Build.Dependency,
    sokolModule: *std.Build.Module,
) !*std.Build.Module {
    return try sk.shdc.createModule(b, "shader", sokolModule, .{
        .shdc_dep = sokol.builder.dependency("shdc", .{}),
        .input = "src/internal/quad.glsl",
        .output = "quad.glsl.zig",
        .slang = .{
            .glsl410 = true,
            .metal_macos = true,
            .hlsl5 = true,
            .glsl300es = true,
            .wgsl = true,
        },
        .reflection = true,
    });
}

// 让 em.js 内容变化体现在 emcc 参数里，避免 Zig 缓存复用旧输出。
fn emJsCacheStamp(b: *std.Build) ![]const u8 {
    const bytes = @embedFile("src/internal/em.js");
    const hash = std.hash.Wyhash.hash(0, bytes);
    const stamp = b.pathFromRoot(b.fmt(".zig-cache/zhu-em-js-{x}.js", .{hash}));

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(b.graph.io, b.pathFromRoot(".zig-cache"));
    try cwd.writeFile(b.graph.io, .{
        .sub_path = stamp,
        .data = "// zhu em.js cache stamp\n",
    });
    return stamp;
}
