//! 使用跨平台 fontbm 生成普通位图字体。
const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const bmfont = @import("bmfont.zig");
const fontChars = @import("chars.zig");

// 字体直接从文件读取，不需要安装字体或提供系统字体名称。
pub const Options = struct {
    font: []const u8, // 相对于客户端项目的字体文件路径。
    input: ?[]const u8 = null, // 文件或目录，默认只生成可打印 ASCII。
    exe: []const u8 = "fontbm",
    size: u16,
    maxSize: u32 = 1024, // 自动选择方形页尺寸，多页使用相同宽高。
    spacing: u8 = 1, // 图集中字形之间的留白，不是排版字距。
    antialias: bool = true,
    images: []const u8 = "font", // 相对于 assets 的专用输出目录，生成前清空。
    output: []const u8 = "src/zon/font.zon",
};

// 注册外部生成命令，缓存中间文件，再复用 BMFont 描述转换。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) !void {
    if (options.size == 0) return error.InvalidFontSize;
    if (options.maxSize == 0 or options.maxSize > 16384) {
        return error.InvalidFontMaxSize;
    }

    const codes = try fontChars.read(b, options.input);
    var content: std.ArrayList(u8) = .empty;
    for (codes) |code| {
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(code, &buffer);
        try content.appendSlice(b.allocator, buffer[0..len]);
    }
    const charset = b.addWriteFiles().add("fontbm.txt", content.items);

    // 小字表选择较小页面；字表较大时由 fontbm 按上限分页。
    var sizes: std.ArrayList(u8) = .empty;
    var size: u32 = 32;
    while (size < options.maxSize) : (size *= 2) {
        try sizes.appendSlice(b.allocator, b.fmt("{}x{},", .{ size, size }));
    }
    try sizes.appendSlice(b.allocator, b.fmt("{}x{}", .{
        options.maxSize, options.maxSize,
    }));

    const generate = b.addSystemCommand(&.{ options.exe, "--font-file" });
    generate.setCwd(b.path("."));
    generate.addFileArg(b.path(options.font));
    generate.addArgs(&.{
        "--font-size",     b.fmt("{}", .{options.size}),
        "--data-format",   "bin",
        "--color",         "255,255,255",
        "--kerning-pairs", "disabled",
        "--spacing-horiz", b.fmt("{}", .{options.spacing}),
        "--spacing-vert",  b.fmt("{}", .{options.spacing}),
        "--texture-size",  sizes.items,
        "--chars-file",
    });
    generate.addFileArg(charset);
    if (!options.antialias) generate.addArg("--monochrome");

    // 输出参数是文件名前缀，目录同时包含 .fnt 和全部 PNG 页面。
    generate.addArg("--output");
    const directory = generate.addOutputDirectoryArg2("fontbm", .{
        .suffix = b.fmt("{s}font", .{std.fs.path.sep_str}),
    });
    generate.has_side_effects = true;
    bmfont.addConvertStep(b, dep, directory.path(b, "font.fnt"), .{
        .images = options.images,
        .output = options.output,
        .name = "fontbm",
    });
}
