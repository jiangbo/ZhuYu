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
    // 单声道复制到左右，双声道取平均合为单声道，仅修改构建缓存中的副本。
    b.dependOnFileContents(stb.path("stb_vorbis.c"));
    const sourcePath = try stb.builder.root.joinString(b.allocator, "stb_vorbis.c");
    const source = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        sourcePath,
        b.allocator,
        .unlimited,
    );
    const patched = try std.mem.replaceOwned(u8, b.allocator, source,
        \\         for (i=0; i < z; ++i)
        \\            *buffer++ = f->channel_buffers[i][f->channel_buffer_start+j];
        \\         for (   ; i < channels; ++i)
        \\            *buffer++ = 0;
    ,
        \\         for (i=0; i < z; ++i) {
        \\            float sample = f->channel_buffers[i][f->channel_buffer_start+j];
        \\            if (channels == 1 && f->channels == 2)
        \\               sample = (sample + f->channel_buffers[1][f->channel_buffer_start+j]) * 0.5f;
        \\            *buffer++ = sample;
        \\         }
        \\         for (   ; i < channels; ++i)
        \\            *buffer++ = f->channels == 1 && channels == 2
        \\               ? f->channel_buffers[0][f->channel_buffer_start+j] : 0;
    );
    if (std.mem.eql(u8, source, patched)) return error.VorbisPatchMismatch;
    const vorbis = b.addWriteFiles().add("stb_vorbis.c", patched);
    zhu.addCSourceFile(.{
        .file = vorbis,
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
