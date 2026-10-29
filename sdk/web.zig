const std = @import("std");
const sokol = @import("sokol");

// 注册安装命令，与 Web 链接共用引擎实际使用的 Emscripten 依赖。
pub fn installEmsdk(b: *std.Build, dep: *std.Build.Dependency) void {
    const sokolModule = dep.module("zhu").import_table.get("sokol").?;
    const emsdk = sokolModule.owner.dependency("emsdk", .{});
    const install = sokol.emSdkInstallStep(b, emsdk, .{});
    b.step("install-emsdk", "Install Emscripten SDK").dependOn(install);
}

// 编译引擎时使用同一份 Emscripten 头文件和浏览器接入代码。
pub fn add(
    b: *std.Build,
    zhu: *std.Build.Module,
    library: *std.Build.Step.Compile,
) void {
    const emsdk = library.root_module.owner.dependency("emsdk", .{});
    zhu.addSystemIncludePath(emsdk.path(
        "upstream/emscripten/cache/sysroot/include",
    ));
    zhu.addCSourceFile(.{ .file = b.path("src/internal/web.c") });
}

// 游戏提供模块和页面配置，目标与优化方式直接取自模块。
pub const WebOptions = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    shell: ?std.Build.LazyPath = null, // 未提供时使用 Emscripten 默认页面。
    extra_args: []const []const u8 = &.{}, // 额外传给 Emscripten 的链接参数。
};

// 构建游戏静态库，再链接并安装 HTML、JS 和 Wasm。
pub fn buildWeb(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: WebOptions,
) !*std.Build.Step.InstallDir {
    const mod = options.root_module;
    const target = mod.resolved_target.?;
    if (target.result.os.tag != .emscripten)
        return error.ExpectedEmscriptenTarget;
    // 使用引擎实际导入的 Sokol，保证编译和链接使用同一份 Emscripten。
    const sokolModule = dep.module("zhu").import_table.get("sokol").?;
    const emsdk = sokolModule.owner.dependency("emsdk", .{});
    const lib = b.addLibrary(.{
        .name = options.name,
        .linkage = .static,
        .root_module = mod,
    });
    return sokol.emLinkStep(b, .{
        .target = target,
        .optimize = mod.optimize,
        .lib_main = lib,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        // TODO: Zig 修复未使用的 std.Io 函数保留问题后，再关闭文件系统。
        // https://codeberg.org/ziglang/zig/issues/31421
        .use_filesystem = true,
        .shell_file_path = options.shell,
        .extra_args = options.extra_args,
    });
}
