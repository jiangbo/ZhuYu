const std = @import("std");

// 构建入口导出此类型，用于选择统一的字体模式。
pub const FontMode = enum { bitmap, msdf, system };

// 固定头文件用于编译 Sokol，目标架构的占位库只用于最终链接。
pub fn add(
    b: *std.Build,
    zhu: *std.Build.Module,
    library: *std.Build.Step.Compile,
) !void {
    const sokol = library.root_module;
    // 构建入口已校验选项；这里只读取原值，避免重复声明选项。
    const gles = if (b.user_input_options.get("gles3")) |value|
        switch (value) {
            .flag => true,
            .scalar => |text| std.mem.eql(u8, text, "true"),
            else => false,
        }
    else
        false;
    const systemFont = if (b.user_input_options.get("font")) |value|
        switch (value) {
            .scalar => |text| std.mem.eql(u8, text, "system"),
            else => false,
        }
    else
        false;
    // 头文件和符号清单按 libc ABI 分开，CPU 架构由目标决定。
    const abi = zhu.resolved_target.?.result.abi;
    if (!abi.isGnu() and !abi.isMusl()) return error.UnsupportedLinuxAbi;
    const name = if (abi.isMusl()) "musl" else "gnu";
    sokol.addSystemIncludePath(b.path(b.fmt("sdk/linux/{s}/include", .{name})));
    inline for (.{
        .{ "asound", 2 },
        .{ "X11", 6 },
        .{ "Xi", 6 },
        .{ "Xcursor", 1 },
    }) |entry| {
        try addLibrary(b, &.{ zhu, sokol }, entry[0], entry[1]);
    }
    if (gles) {
        // GLES 3.x 同样使用 libGLESv2，避免依赖桌面 GL 库的导出集合。
        try addLibrary(b, &.{ zhu, sokol }, "GLESv2", 2);
        try addLibrary(b, &.{ zhu, sokol }, "EGL", 1);
    } else {
        try addLibrary(b, &.{ zhu, sokol }, "GL", 1);
    }
    // 字体符号清单手工维护，位图和 MSDF 不需要字体占位库。
    if (systemFont) {
        inline for (.{
            .{ "freetype", 6 },
            .{ "fontconfig", 1 },
        }) |entry| {
            try addLibrary(b, &.{zhu}, entry[0], entry[1]);
        }
    }
}

// 按清单生成同一目标的 ELF 占位库，向使用模块提供库搜索目录。
fn addLibrary(
    b: *std.Build,
    modules: []const *std.Build.Module,
    comptime name: []const u8,
    major: u32,
) !void {
    // 两套清单独立保存，保留各自真实导出和符号版本。
    const target = modules[0].resolved_target.?;
    const symbols = if (target.result.abi.isMusl())
        @embedFile("defs/linux/musl/" ++ name ++ ".def")
    else
        @embedFile("defs/linux/gnu/" ++ name ++ ".def");
    const options = b.addOptions();
    options.addOption([]const u8, "symbols", symbols);
    const root = b.createModule(.{
        .root_source_file = b.path("sdk/linux.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    root.addOptions("options", options);
    const library = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .version = .{ .major = major, .minor = 0, .patch = 0 },
        .root_module = root,
    });
    try addVersions(b, library, symbols);
    // 生成目录自带 libxxx.so 链接名，库名由 Sokol 或引擎声明。
    const path = library.getEmittedBinDirectory();
    for (modules) |module| module.addLibraryPath(path);
}

// @@ 导出需要对应的版本节点，让最终程序记录正确的符号版本要求。
fn addVersions(
    b: *std.Build,
    library: *std.Build.Step.Compile,
    symbols: []const u8,
) !void {
    var versions = std.StringHashMap(void).init(b.allocator);
    var script: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, symbols, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        const start = std.mem.indexOf(u8, name, "@@") orelse continue;
        const version = name[start + 2 ..];
        const entry = try versions.getOrPut(version);
        if (entry.found_existing) continue;
        try script.appendSlice(b.allocator, b.fmt("{s} {{}};\n", .{version}));
    }
    if (script.items.len == 0) return;
    const files = b.addWriteFiles();
    const path = files.add(b.fmt("{s}.map", .{library.name}), script.items);
    library.setVersionScript(path);
}

// 仅作为占位库根文件编译时读取清单并导出，构建脚本导入时不导出。
// 名称保留默认版本后缀 @@版本；数据符号额外记录类型和字节数。
comptime {
    if (@import("root") == @This()) {
        @setEvalBranchQuota(1_000_000);
        const options = @import("options");
        var lines = std.mem.tokenizeScalar(u8, options.symbols, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t\r");
            const name = fields.next() orelse continue;
            if (fields.next()) |kind| {
                if (!std.mem.eql(u8, kind, "data"))
                    @compileError("invalid stub kind");
                const size = std.fmt.parseInt(usize, fields.next().?, 10) catch
                    @compileError("invalid stub size");
                @export(&Data(name, size).bytes, .{ .name = name });
            } else {
                @export(&stub, .{ .name = name });
            }
        }
    }
}

// 占位函数不随程序发布，误执行时立即终止。
fn stub() callconv(.c) void {
    @trap();
}

// 不同名称拥有独立的数据符号，大小由目标库的 ABI 清单提供。
fn Data(comptime name: []const u8, comptime size: usize) type {
    return struct {
        const symbol = name;
        var bytes: [size]u8 align(16) = undefined;
    };
}
