const std = @import("std");

// 应用直接使用同一版本的 Sokol 构建工具。
pub const sokol = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = target.result.os.tag == .emscripten;
    // 编译期决定菜单文字是否自动使用 MSDF 管线。
    const msdf = b.option(bool, "msdf", "Use MSDF for menu text") orelse false;
    const buildOptions = b.addOptions();
    buildOptions.addOption(bool, "msdf", msdf);

    const sokolDep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokolModule = sokolDep.module("sokol");
    const shader = try createShader(b, sokolDep, target.result);

    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Web 由 emcc 链接，关闭 C 的 UBSan。
        .sanitize_c = if (web) .off else null,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);
    zhu.addOptions("build_options", buildOptions);
    if (web) {
        const em = sokolDep.builder.dependency("emsdk", .{});
        const include = em.path("upstream/emscripten/cache/sysroot/include");
        zhu.addSystemIncludePath(include);
        // 静态接入浏览器存档函数，无需应用额外配置链接参数。
        zhu.addCSourceFile(.{ .file = b.path("src/internal/web.c") });
    }
    try addVorbis(b, zhu);

    const tests = b.addTest(.{ .root_module = zhu });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

// 游戏提供动态库名称和模块，安卓平台配置由引擎统一处理。
pub const AndroidOptions = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    ndk: []const u8, // Android NDK 目录，由游戏构建选项传入。
};

// 在游戏构建缓存中补充安卓入口配置，生成 NativeActivity 加载的动态库。
pub fn buildAndroid(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: AndroidOptions,
) !*std.Build.Step.Compile {
    const mod = options.root_module;
    const zhu = dep.module("zhu");
    // 按模块对象查找游戏设置的导入名，不要求用户使用固定别名。
    var imports = mod.import_table.iterator();
    const importName = while (imports.next()) |entry| {
        if (entry.value_ptr.* == zhu) break entry.key_ptr.*;
    } else "zhu";
    // 追踪游戏入口内容，从模块本身取得源码路径和所属项目。
    const rootFile = mod.root_source_file.?;
    const src = rootFile.src_path;
    b.dependOnFileContents(rootFile);
    const path = try src.owner.root.joinString(b.allocator, src.sub_path);
    const source = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, //
        path, b.allocator, .unlimited);
    // 完整复制源码目录，保留所有文件和原有的相对导入关系。
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(rootFile.dirname(), "", .{});
    mod.root_source_file = files.add("zhuyu_android_main.zig", //
        b.fmt("{0s}\n\n// 动态库显式分析窗口模块，保留引擎导出的入口和回调。\n" ++
            "comptime {{\n    _ = @import(\"{1f}\").window;\n}}\n\n" ++
            "// 安卓日志和 panic 由引擎直接输出到 Logcat。\n" ++
            "pub const std_options: @import(\"std\").Options = .{{\n" ++
            "    // 沿用安卓系统的备用信号栈，缩减动态库体积。\n" ++
            "    .signal_stack_size = null,\n" ++
            "    .logFn = @import(\"{1f}\").android.log,\n}};\n" ++
            "pub const panic = @import(\"{1f}\").android.panic;\n", .{
            source,
            std.zig.fmtString(importName),
        }));

    // 配置引擎和 Sokol 使用的 NDK、系统库及 APK 资源读取。
    const target = zhu.resolved_target.?;
    // 取回创建引擎依赖时使用的同一份 Sokol，配置在实际编译前生效。
    const sokolDep = dep.builder.dependency("sokol", .{
        .target = target,
        .optimize = zhu.optimize.?,
    });

    const host = switch (b.graph.host.result.os.tag) {
        .windows => "windows-x86_64",
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        else => @panic("Unsupported NDK host"),
    };
    const sysroot = b.pathJoin(&.{
        options.ndk,
        "toolchains",
        "llvm",
        "prebuilt",
        host,
        "sysroot",
    });
    const include = b.pathJoin(&.{ sysroot, "usr", "include" });
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => return error.UnsupportedAndroidTarget,
    };
    const archInclude = b.pathJoin(&.{ include, arch });
    const libraries = b.pathJoin(&.{
        sysroot,
        "usr",
        "lib",
        arch,
        b.fmt("{d}", .{target.result.os.version_range.linux.android}),
    });
    // 引擎和 Sokol 使用同一套 NDK，最终动态库复用这份链接配置。
    const sokolLib = sokolDep.artifact("sokol_clib");
    for ([_]*std.Build.Module{ zhu, sokolLib.root_module }) |module| {
        module.addSystemIncludePath(.{ .cwd_relative = include });
        module.addSystemIncludePath(.{ .cwd_relative = archInclude });
        module.addLibraryPath(.{ .cwd_relative = libraries });
        module.pic = true;
    }
    const config = b.fmt(
        "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\ncc_dir={s}\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir=\n",
        .{ include, archInclude, libraries, libraries },
    );
    const libc = b.addWriteFiles().add("android-libc.conf", config);
    sokolLib.setLibCFile(libc);
    // GLES、EGL、android、log 继续由 Sokol 声明。
    zhu.linkSystemLibrary("aaudio", .{});
    zhu.linkSystemLibrary("m", .{});
    // 系统库改为最终动态库的文件输入，绕过 Zig 的 LLD 库路径参数问题。
    // TODO: Zig 修复后，验证系统库声明可直接链接，再移除下面的转换。
    // https://codeberg.org/ziglang/zig/issues/37257
    // 文件输入不会像系统库声明一样从 Sokol 静态库传递到最终链接。
    for ([_]*std.Build.Module{ zhu, sokolLib.root_module }) |module| {
        var index: usize = 0;
        while (index < module.link_objects.items.len) {
            switch (module.link_objects.items[index]) {
                .system_lib => |system| {
                    mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{
                        libraries, b.fmt("lib{s}.so", .{system.name}),
                    }) });
                    _ = module.link_objects.orderedRemove(index);
                },
                else => index += 1,
            }
        }
    }

    try patchFetch(b, sokolDep);
    zhu.addIncludePath(sokolDep.path("src/sokol/c"));
    zhu.addCSourceFile(.{
        .file = dep.path("src/internal/android.c"),
    });

    // 游戏动态库直接复用同一份库路径和 libc 配置。
    mod.pic = true;
    mod.link_libc = true;
    mod.addLibraryPath(.{ .cwd_relative = libraries });
    const lib = b.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .root_module = mod,
    });
    lib.setLibCFile(libc);
    lib.link_z_defs = true;
    lib.link_z_max_page_size = 16384;
    lib.link_z_common_page_size = 16384;
    return lib;
}

// 添加 Vorbis 解码器，在缓存副本中处理单声道和双声道转换。
fn addVorbis(b: *std.Build, zhu: *std.Build.Module) !void {
    const stb = b.dependency("stb", .{
        .target = zhu.resolved_target.?,
        .optimize = zhu.optimize.?,
    });
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
        \\               sample = (sample +
        \\                  f->channel_buffers[1][f->channel_buffer_start+j]) * 0.5f;
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
