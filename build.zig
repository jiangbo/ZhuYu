const std = @import("std");
// 应用直接使用同一版本的 Sokol 构建工具。
pub const sokol = @import("sokol");

const linuxSdk = @import("sdk/linux.zig");
const macosSdk = @import("sdk/macos.zig");
const iosSdk = @import("sdk/ios.zig");
const androidSdk = @import("sdk/android.zig");
const webSdk = @import("sdk/web.zig");
const windowsSdk = @import("sdk/windows.zig");

// 每次构建只选择一种字体模式。
pub const FontMode = linuxSdk.FontMode;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 初始化和绘制共用同一个编译期字体选择。
    const font = b.option(FontMode, "font", "Font mode") orelse .static;
    // 仅切换 Linux 桌面后端，Android 和 Web 继续使用各自的默认后端。
    const gles = b.option(bool, "gles3", "Use GLES3 on Linux") orelse false;
    const append = b.option(bool, "append", "Append asset pack") orelse false;
    // 默认按纹理绑定一个采样器，开启后允许实例分别选择过滤方式。
    const samplers = b.option(bool, "samplers", "Use two samplers") orelse false;
    const imgui = b.option(bool, "imgui", "Enable ImGui") orelse false;
    const action = b.option(std.Build.LazyPath, "action", "Action bindings zon") orelse
        b.addWriteFiles().add("action.zon", ".{}");
    const options = b.addOptions();
    options.addOption(FontMode, "font", font);
    // append 只对桌面目标生效，其他目标继续使用各自的资产加载方式。
    options.addOption(bool, "append", switch (target.result.os.tag) {
        .windows, .macos => append,
        .linux => append and !target.result.abi.isAndroid(),
        else => false,
    });
    options.addOption(bool, "samplers", samplers);

    // 参数读取完成后，统一计算平台和构建方式。
    const linuxOnly = target.result.os.tag == .linux and !target.result.abi.isAndroid();
    const linuxGles = linuxOnly and gles;

    const sokolDep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gles3 = linuxGles,
        .egl = linuxGles,
        .with_sokol_imgui = imgui,
    });
    const sokolLibrary = sokolDep.artifact("sokol_clib");
    sokolLibrary.lto = if (optimize == .debug) .none else .full;
    b.installArtifact(sokolLibrary);
    const sokolModule = sokolDep.module("sokol");
    const shader = try createQuadShader(b, sokolDep, target.result, samplers);

    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/zhu.zig"),
        .target = target,
        .optimize = optimize,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);
    zhu.addAnonymousImport("action", .{ .root_source_file = action });
    zhu.addOptions("options", options);

    if (target.result.os.tag == .ios) {
        // iOS 单独链接色彩空间接口；macOS 通过 AppKit 重导出提供。
        zhu.linkFramework("CoreGraphics", .{});
    }
    if (target.result.os.tag == .windows) {
        zhu.linkSystemLibrary("shell32", .{});
        zhu.linkSystemLibrary("ole32", .{});
    }
    if (font == .system) linkSystemFont(zhu);
    if (target.result.abi.isAndroid()) {
        if (target.result.os.version_range.linux.android < 26)
            return error.AndroidRequiresApi26;
        // GLES、EGL、android、log 继续由 Sokol 声明。
        zhu.linkSystemLibrary("aaudio", .{});
        zhu.linkSystemLibrary("m", .{});
        zhu.pic = true;
        sokolLibrary.root_module.pic = true;
    }

    // 仅交叉构建接入包内 SDK，本机构建使用本机开发环境。
    if (!target.query.isNative()) return buildCross(b, zhu, sokolDep);

    const tests = b.addTest(.{ .root_module = zhu });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

// 系统字体依赖集中声明，在平台 SDK 处理链接输入前调用。
fn linkSystemFont(zhu: *std.Build.Module) void {
    const target = zhu.resolved_target.?.result;
    switch (target.os.tag) {
        .linux => {
            if (target.abi.isAndroid()) return;
            // Linux 桌面通过 Fontconfig 选字，FreeType 生成字形。
            zhu.linkSystemLibrary("freetype", .{});
            zhu.linkSystemLibrary("fontconfig", .{});
        },
        .macos, .ios => {
            // Apple 共用 CoreText 度量和 CoreGraphics 离屏绘制。
            zhu.linkFramework("CoreText", .{});
            zhu.linkFramework("CoreGraphics", .{});
        },
        .windows => {
            // DirectWrite 生成灰度字形，GDI 读取离屏位图。
            zhu.linkSystemLibrary("dwrite", .{});
            zhu.linkSystemLibrary("gdi32", .{});
        },
        else => {},
    }
}

// 需要 SDK 的平台接入和测试产物配置集中在此处。
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
        .windows => if (target.abi == .msvc) {
            libc = try windowsSdk.add(b, zhu, library);
        },
        else => {},
    }
    const tests = b.addTest(.{ .root_module = zhu });
    if (libc) |file| tests.setLibCFile(file);
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

pub const ShaderOptions = struct {
    name: []const u8,
    input: []const u8,
    output: []const u8,
    defines: ?[][]const u8 = null,
};

// 为游戏模块编译自定义 GLSL 着色器，复用引擎的 Sokol、shdc 和平台格式。
pub fn createShader(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: ShaderOptions,
) !*std.Build.Module {
    const zhu = dep.module("zhu");
    const sokolModule = zhu.import_table.get("sokol").?;
    const shdc = sokolModule.owner.dependency("shdc", .{});
    const target = zhu.resolved_target.?.result;
    return createShaderModule(b, sokolModule, shdc, target, options);
}

// 生成目标平台的着色器模块。
fn createQuadShader(
    b: *std.Build,
    sokolDep: *std.Build.Dependency,
    target: std.Target,
    samplers: bool,
) !*std.Build.Module {
    const sokolModule = sokolDep.module("sokol");
    const shdc = sokolDep.builder.dependency("shdc", .{});
    var defines = [_][]const u8{"SAMPLERS"};
    return createShaderModule(b, sokolModule, shdc, target, .{
        .name = "shader",
        .input = "src/internal/quad.glsl",
        .output = "quad.glsl.zig",
        .defines = if (samplers) &defines else null,
    });
}

fn createShaderModule(
    b: *std.Build,
    sokolModule: *std.Build.Module,
    shdc: *std.Build.Dependency,
    target: std.Target,
    options: ShaderOptions,
) !*std.Build.Module {
    return try sokol.shdc.createModule(b, options.name, sokolModule, .{
        .shdc_dep = shdc,
        .input = options.input,
        .output = options.output,
        .defines = options.defines,
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
pub const bmfont = @import("tools/bmfont.zig");

// fontbm 原生跨平台运行，输出普通位图字体。
pub const fontbm = @import("tools/fontbm.zig");

// MSDF 的参数和生成流程由工具自身管理。
pub const msdf = @import("tools/msdf.zig");

// 音频转换工具在宿主上调用 FFmpeg，游戏不引入转码依赖。
pub const audio = @import("tools/audio.zig");

// 资源转换工具在宿主上运行，按需注册游戏项目的构建命令。
pub const atlas = @import("tools/atlas.zig");
pub const copy = @import("tools/copy.zig");

pub const tiled = @import("tools/tiled.zig");

// Android 应用属性与 APK 打包步骤。
pub const apk = @import("tools/apk.zig");

// 为 iOS 真机和模拟器生成 .app，提供应用属性和打包步骤。
pub const ios = @import("tools/ios.zig");

// 资源打包及桌面程序追加步骤。
pub const pack = @import("tools/pack.zig");

// 安卓构建的类型和实现统一放在平台模块中。
pub const AndroidOptions = androidSdk.AndroidOptions;
pub const buildAndroid = androidSdk.buildAndroid;

// Web 构建的类型和实现统一放在平台模块中。
pub const WebOptions = webSdk.WebOptions;
pub const buildWeb = webSdk.buildWeb;
pub const installEmsdk = webSdk.installEmsdk;
