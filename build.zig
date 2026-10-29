const std = @import("std");
const linuxSdk = @import("sdk/linux.zig");
const macosSdk = @import("sdk/macos.zig");
const iosSdk = @import("sdk/ios.zig");
const androidSdk = @import("sdk/android.zig");
const webSdk = @import("sdk/web.zig");

// 应用直接使用同一版本的 Sokol 构建工具。
pub const sokol = @import("sokol");

// 每次构建只选择一种字体模式。
pub const FontMode = linuxSdk.FontMode;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 初始化和绘制共用同一个编译期字体选择。
    const font = b.option(FontMode, "font", "Font mode") orelse .bitmap;
    // 仅切换 Linux 桌面后端，Android 和 Web 继续使用各自的默认后端。
    const gles = b.option(bool, "gles3", "Use GLES3 on Linux") orelse false;
    // 应用创建依赖时传入，开启后只从程序尾部的资源包加载。
    const append = b.option(bool, "append", "Append asset pack") orelse false;
    // 不使用 MIDI 的应用不编译播放器和内置音色。
    const midi = b.option(bool, "midi", "Enable MIDI music") orelse false;
    const options = b.addOptions();
    options.addOption(FontMode, "font", font);
    options.addOption(bool, "append", append);
    options.addOption(bool, "midi", midi);

    // 参数读取完成后，统一计算平台和构建方式。
    const linuxOnly = target.result.os.tag == .linux and !target.result.abi.isAndroid();
    const linuxGles = linuxOnly and gles;

    const sokolDep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gles3 = linuxGles,
        .egl = linuxGles,
    });
    const sokolModule = sokolDep.module("sokol");
    const shader = try createShader(b, sokolDep, target.result);

    const web = target.result.os.tag == .emscripten;
    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Web 由 emcc 链接，关闭 C 的 UBSan。
        .sanitize_c = if (web) .off else null,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);
    zhu.addOptions("options", options);

    // 本机与交叉构建共用平台库声明和 GLES 库名修正。
    if (linuxOnly) {
        if (linuxGles) {
            fixLinuxGles(sokolDep.artifact("sokol_clib").root_module);
        }
        if (font == .system) {
            // 系统字体统一声明依赖，交叉构建另行提供占位库。
            zhu.linkSystemLibrary("freetype", .{});
            zhu.linkSystemLibrary("fontconfig", .{});
        }
    }
    if (target.result.os.tag == .ios) {
        // iOS 单独链接色彩空间接口；macOS 通过 AppKit 重导出提供。
        zhu.linkFramework("CoreGraphics", .{});
    }
    if (target.result.abi.isAndroid()) {
        if (target.result.os.version_range.linux.android < 26)
            return error.AndroidRequiresApi26;
        // GLES、EGL、android、log 继续由 Sokol 声明。
        zhu.linkSystemLibrary("aaudio", .{});
        zhu.linkSystemLibrary("m", .{});
        zhu.pic = true;
        sokolDep.artifact("sokol_clib").root_module.pic = true;
    }

    // 非 native 交给独立流程，本机构建直接继续向下执行。
    const native = target.query.isNative();
    if (!native) return buildCross(b, zhu, sokolDep);

    const tests = b.addTest(.{ .root_module = zhu });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

// 非 native 的 SDK、Web 接入和测试产物配置集中在此处。
fn buildCross(
    b: *std.Build,
    zhu: *std.Build.Module,
    sokolDep: *std.Build.Dependency,
) !void {
    const target = zhu.resolved_target.?.result;
    const library = sokolDep.artifact("sokol_clib");
    var libc: ?std.Build.LazyPath = null;
    switch (target.os.tag) {
        .linux => {
            if (target.abi.isAndroid()) {
                libc = try androidSdk.add(b, zhu, library);
            } else {
                try linuxSdk.add(b, zhu, library);
            }
        },
        .macos => libc = try macosSdk.add(b, zhu, library),
        .ios => libc = try iosSdk.add(b, zhu, library),
        .emscripten => webSdk.add(b, zhu, library),
        else => {},
    }
    const tests = b.addTest(.{ .root_module = zhu });
    if (libc) |file| tests.setLibCFile(file);
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

// native 与非 native 的 GLES 构建共用此库名修正。
fn fixLinuxGles(module: *std.Build.Module) void {
    // TODO: 升级到包含上游修复的 sokol-zig 后，移除此库名替换。
    for (module.link_objects.items) |*object| {
        switch (object.*) {
            .system_lib => |*library| {
                if (std.mem.eql(u8, library.name, "GL"))
                    library.name = "GLESv2";
            },
            else => {},
        }
    }
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
                .{ .glsl410 = true, .glsl300es = true },
            .emscripten => .{ .glsl300es = true, .wgsl = true },
            else => return error.UnsupportedShaderTarget,
        },
    });
}

// 最终产物复用引擎构建时的 libc 配置。
pub const setLibC = androidSdk.setLibC;

// BMFont 的参数和生成流程由工具自身管理。
pub const bmfont = struct {
    pub const Options = @import("tools/bmfont.zig").Options;
    pub const addStep = @import("tools/bmfont.zig").addStep;
};

// fontbm 原生跨平台运行，输出普通位图字体。
pub const fontbm = struct {
    pub const Options = @import("tools/fontbm.zig").Options;
    pub const addStep = @import("tools/fontbm.zig").addStep;
};

// MSDF 的参数和生成流程由工具自身管理。
pub const msdf = struct {
    pub const Options = @import("tools/msdf.zig").Options;
    pub const addStep = @import("tools/msdf.zig").addStep;
};

// 音频转换工具在宿主上调用 FFmpeg，游戏不引入转码依赖。
pub const audio = struct {
    pub const Options = @import("tools/audio.zig").Options;
    pub const addStep = @import("tools/audio.zig").addStep;
};

// 资源转换工具在宿主上运行，按需注册游戏项目的构建命令。
pub const atlas = struct {
    pub const Options = @import("tools/atlas.zig").Options;
    pub const addStep = @import("tools/atlas.zig").addStep;
};

pub const tiled = struct {
    pub const Options = @import("tools/tiled.zig").Options;
    pub const addStep = @import("tools/tiled.zig").addStep;
};

// Android 应用属性与 APK 打包步骤。
pub const apk = struct {
    pub const AppConfig = @import("tools/apk.zig").AppConfig;
    pub const Options = @import("tools/apk.zig").Options;
    pub const addStep = @import("tools/apk.zig").addStep;
};

// 为 iOS 真机和模拟器生成 .app，提供应用属性和打包步骤。
pub const ios = struct {
    pub const AppConfig = @import("tools/ios.zig").AppConfig;
    pub const Options = @import("tools/ios.zig").Options;
    pub const addStep = @import("tools/ios.zig").addStep;
};

// 资源打包及桌面程序追加步骤。
pub const pack = struct {
    pub const Options = @import("tools/pack.zig").Options;
    pub const addStep = @import("tools/pack.zig").addStep;
};

// 安卓构建的类型和实现统一放在平台模块中。
pub const AndroidOptions = androidSdk.AndroidOptions;
pub const buildAndroid = androidSdk.buildAndroid;

// Web 构建的类型和实现统一放在平台模块中。
pub const WebOptions = webSdk.WebOptions;
pub const buildWeb = webSdk.buildWeb;
pub const installEmsdk = webSdk.installEmsdk;
