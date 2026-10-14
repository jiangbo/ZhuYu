const std = @import("std");

// 应用直接使用同一版本的 Sokol 构建工具。
pub const sokol = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = target.result.os.tag == .emscripten;

    const sokolDep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokolModule = sokolDep.module("sokol");
    const shader = try createShader(b, sokolDep, web);

    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Web 由 emcc 链接，关闭 C 的 UBSan。
        .sanitize_c = if (web) .off else null,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);

    const stb = b.dependency("stb", .{
        .target = target,
        .optimize = optimize,
    });
    if (web) {
        const em = sokolDep.builder.dependency("emsdk", .{});
        const include = em.path("upstream/emscripten/cache/sysroot/include");
        zhu.addSystemIncludePath(include);
    }
    zhu.addCSourceFile(.{
        .file = stb.path("stb_vorbis.c"),
        .flags = &.{
            "-O2",
            "-DSTB_VORBIS_NO_PUSHDATA_API",
            "-DSTB_VORBIS_NO_INTEGER_CONVERSION",
            "-DSTB_VORBIS_NO_STDIO",
        },
    });

    const tests = b.addTest(.{ .root_module = zhu });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

fn createShader(
    b: *std.Build,
    sokolDep: *std.Build.Dependency,
    web: bool,
) !*std.Build.Module {
    const sokolModule = sokolDep.module("sokol");
    return try sokol.shdc.createModule(b, "shader", sokolModule, .{
        .shdc_dep = sokolDep.builder.dependency("shdc", .{}),
        .input = "src/internal/quad.glsl",
        .output = "quad.glsl.zig",
        // Web 只生成 WebGL2 和 WebGPU 对应的 shader。
        .slang = .{
            .glsl410 = !web,
            .metal_macos = !web,
            .hlsl5 = !web,
            .glsl300es = web,
            .wgsl = web,
        },
    });
}
