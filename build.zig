const std = @import("std");
const sk = @import("sokol");

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

// Web 链接需要的 zhu 参数。
pub fn webArgs(
    b: *std.Build,
    zhu: *std.Build.Dependency,
) ![]const []const u8 {
    const args = try b.allocator.alloc([]const u8, 4);
    args[0] = "--js-library";
    args[1] = zhu.path("src/internal/em.js").getPath(b);
    args[2] = "--pre-js";
    args[3] = try emJsCacheStamp(b);
    return args;
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
