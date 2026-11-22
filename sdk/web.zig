const std = @import("std");
const sokol = @import("sokol");

// 注册安装命令，与 Web 链接共用引擎实际使用的 Emscripten 依赖。
pub fn installEmsdk(b: *std.Build, dep: *std.Build.Dependency) void {
    const sokolModule = dep.module("zhu").import_table.get("sokol").?;
    const emsdk = sokolModule.owner.dependency("emsdk", .{});
    const install = sokol.emSdkInstallStep(b, emsdk, .{});
    b.step("install-emsdk", "Install Emscripten SDK").dependOn(install);
}

// 游戏提供模块和页面配置，目标与优化方式直接取自模块。
pub const WebOptions = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    shell: ?std.Build.LazyPath = null, // 未提供时使用 Emscripten 默认页面。
    extra_args: []const []const u8 = &.{}, // 额外传给 Emscripten 的链接参数。
    hash: bool = true, // 为产出的 JS 和 Wasm 添加内容哈希文件名。
};

// 构建游戏静态库，再链接并安装 HTML、JS 和 Wasm。
pub fn buildWeb(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: WebOptions,
) !*std.Build.Step {
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
    const install = try sokol.emLinkStep(b, .{
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
        .js_libraries = &.{dep.path("src/internal/web.js")},
        // 显式保留 Zig 导出给 JS 的回调，再合入应用的链接参数。
        .extra_args = try std.mem.concat(b.allocator, []const u8, &.{
            &.{
                "-Wl,--export=zhu_fetch_done",
                "-Wl,--export=zhu_fetch_alloc",
            },
            options.extra_args,
        }),
    });
    if (!options.hash) return &install.step;

    const tool = b.addExecutable(.{
        .name = "zhuyu-web-hash",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("sdk/web.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.setCwd(.{ .relative = .{ .base = .install_prefix } });
    run.addArg("web");
    run.addArg(options.name);
    run.has_side_effects = true;
    run.step.dependOn(&install.step);
    return &run.step;
}

// 为 Emscripten 产出的 JS 和 Wasm 添加内容哈希文件名，并更新入口 HTML 引用。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.InvalidArguments;

    const webDir = args[1];
    const name = args[2];

    var dir = try std.Io.Dir.cwd().openDir(io, webDir, .{ .iterate = true });
    defer dir.close(io);

    const wasmName = try std.fmt.allocPrint(gpa, "{s}.wasm", .{name});
    const jsName = try std.fmt.allocPrint(gpa, "{s}.js", .{name});
    const htmlName = try std.fmt.allocPrint(gpa, "{s}.html", .{name});

    const wasmHash = try hashFile(io, dir, gpa, wasmName);
    const jsHash = try hashFile(io, dir, gpa, jsName);
    const hashedWasm = try std.fmt.allocPrint(gpa, "{s}.{x:0>16}.wasm", .{
        name,
        wasmHash,
    });
    const hashedJs = try std.fmt.allocPrint(gpa, "{s}.{x:0>16}.js", .{
        name,
        jsHash,
    });

    // 清理旧的哈希产物，避免 web 目录堆积历史文件。
    const prefix = try std.fmt.allocPrint(gpa, "{s}.", .{name});
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const isWasm = std.mem.endsWith(u8, entry.name, ".wasm");
        const isJs = std.mem.endsWith(u8, entry.name, ".js");
        if (!isWasm and !isJs) continue;
        if (std.mem.eql(u8, entry.name, wasmName) or
            std.mem.eql(u8, entry.name, jsName) or
            std.mem.eql(u8, entry.name, hashedWasm) or
            std.mem.eql(u8, entry.name, hashedJs)) continue;
        try dir.deleteFile(io, entry.name);
    }

    try dir.rename(wasmName, dir, hashedWasm, io);
    try dir.rename(jsName, dir, hashedJs, io);

    const html = try dir.readFileAlloc(io, htmlName, gpa, .unlimited);
    const srcMarker = try std.fmt.allocPrint(gpa, "src=\"{s}\"", .{jsName});
    const srcPos = std.mem.indexOf(u8, html, srcMarker) orelse
        return error.ScriptTagNotFound;
    const tagPos = std.mem.lastIndexOf(u8, html[0..srcPos], "<script") orelse
        return error.ScriptTagNotFound;

    const hook = try std.fmt.allocPrint(
        gpa,
        "<script>Module=globalThis.Module||{{}};" ++
            "Module.locateFile=(p,d)=>(d||\"\")+" ++
            "(p===\"{s}\"?\"{s}\":p);</script>\n    ",
        .{ wasmName, hashedWasm },
    );
    const newSrc = try std.fmt.allocPrint(gpa, "src=\"{s}\"", .{hashedJs});
    const nextHtml = try std.mem.concat(gpa, u8, &.{
        html[0..tagPos],
        hook,
        html[tagPos..srcPos],
        newSrc,
        html[srcPos + srcMarker.len ..],
    });
    try dir.writeFile(io, .{ .sub_path = htmlName, .data = nextHtml });
}

fn hashFile(
    io: std.Io,
    dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    subPath: []const u8,
) !u64 {
    const bytes = try dir.readFileAlloc(io, subPath, gpa, .unlimited);
    return std.hash.Wyhash.hash(0, bytes);
}
