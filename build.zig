const std = @import("std");

// 应用直接使用同一版本的 Sokol 构建工具。
pub const sokol = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = target.result.os.tag == .emscripten;
    const android = target.result.abi.isAndroid();

    const sokolDep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dont_link_system_libs = android,
    });
    const sokolModule = sokolDep.module("sokol");
    const shader = try createShader(b, sokolDep, target.result);

    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Web 和 Android 均不引入 C 的 UBSan 运行时。
        .sanitize_c = if (web or android) .off else null,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);
    if (android) {
        try patchFetch(b, sokolDep);
        zhu.addIncludePath(sokolDep.path("src/sokol/c"));
        zhu.addCSourceFile(.{
            // 临时的 APK 资源读取适配在构建缓存生成。
            .file = b.addWriteFiles().add("android.c",
                \\#define _BSD_SOURCE 1
                \\#include <android/asset_manager.h>
                \\#include <android/native_activity.h>
                \\#include <stdio.h>
                \\#include <string.h>
                \\#include "sokol_app.h"
                \\
                \\static int asset_read(void* asset, char* buffer, int size) {
                \\    return AAsset_read((AAsset*)asset, buffer, size);
                \\}
                \\
                \\static fpos_t asset_seek(void* asset, fpos_t offset, int origin) {
                \\    return AAsset_seek((AAsset*)asset, offset, origin);
                \\}
                \\
                \\static int asset_close(void* asset) {
                \\    AAsset_close((AAsset*)asset);
                \\    return 0;
                \\}
                \\
                \\// assets/ 路径读取 APK，其余路径使用普通文件系统。
                \\FILE* zhu_android_fopen(const char* path) {
                \\    if (strncmp(path, "assets/", 7) != 0) return fopen(path, "rb");
                \\    ANativeActivity* activity =
                \\        (ANativeActivity*)sapp_android_get_native_activity();
                \\    AAsset* asset = AAssetManager_open(activity->assetManager,
                \\        path + 7, AASSET_MODE_RANDOM);
                \\    if (!asset) return NULL;
                \\    FILE* stream = funopen(asset, asset_read, NULL,
                \\        asset_seek, asset_close);
                \\    if (!stream) AAsset_close(asset);
                \\    return stream;
                \\}
            ),
            .flags = &.{"-fPIC"},
        });
    }

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

// 只替换构建缓存中的 fetch 实现，保留 Sokol 原来的线程和回调流程。
fn patchFetch(b: *std.Build, dep: *std.Build.Dependency) !void {
    const header = dep.path("src/sokol/c/sokol_fetch.h");
    b.dependOnFileContents(header);
    const path = try dep.builder.root.joinString(
        b.allocator,
        "src/sokol/c/sokol_fetch.h",
    );
    const source = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .unlimited,
    );
    const old = "return fopen(path->buf, \"rb\");";
    if (std.mem.count(u8, source, old) != 1) return error.FetchPatchMismatch;
    const patched = try std.mem.replaceOwned(
        u8,
        b.allocator,
        source,
        old,
        "return zhu_android_fopen(path->buf);",
    );
    const files = b.addWriteFiles();
    _ = files.add("sokol_fetch.h", patched);
    const wrapper = files.add("sokol_fetch.c",
        \\#include "sokol_defines.h"
        \\#include <stdio.h>
        \\extern FILE* zhu_android_fopen(const char* path);
        \\#define SOKOL_FETCH_IMPL
        \\#include "sokol_fetch.h"
    );
    const module = dep.artifact("sokol_clib").root_module;
    module.addIncludePath(dep.path("src/sokol/c"));
    var count: usize = 0;
    for (module.link_objects.items) |object| {
        switch (object) {
            .c_source_file => |file| {
                if (file.file != .src_path) continue;
                const name = std.fs.path.basename(file.file.src_path.sub_path);
                if (!std.mem.eql(u8, name, "sokol_fetch.c")) continue;
                file.file = wrapper;
                count += 1;
            },
            else => {},
        }
    }
    if (count != 1) return error.FetchSourceMismatch;
}

fn createShader(
    b: *std.Build,
    sokolDep: *std.Build.Dependency,
    target: std.Target,
) !*std.Build.Module {
    const sokolModule = sokolDep.module("sokol");
    return try sokol.shdc.createModule(b, "shader", sokolModule, .{
        .shdc_dep = sokolDep.builder.dependency("shdc", .{}),
        .input = "src/internal/quad.glsl",
        .output = "quad.glsl.zig",
        // 保留对应平台可能使用的 shader 格式。
        .slang = switch (target.os.tag) {
            .windows => .{ .hlsl5 = true, .glsl410 = true },
            .macos => .{ .metal_macos = true, .glsl410 = true },
            .ios => if (target.abi == .simulator)
                .{ .metal_sim = true }
            else
                .{ .metal_ios = true },
            .linux => if (target.abi.isAndroid())
                .{ .glsl300es = true }
            else
                .{ .glsl410 = true },
            .emscripten => .{ .glsl300es = true, .wgsl = true },
            else => return error.UnsupportedShaderTarget,
        },
    });
}
