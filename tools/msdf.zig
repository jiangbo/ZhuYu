const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const text = @import("text");

// 游戏配置字体生成，路径以游戏项目为起点。
pub const Options = struct {
    font: []const u8,
    charset: ?Build.LazyPath = null, // 默认生成 ASCII，沿用官方字符集语法。
    exe: []const u8 = "msdf-atlas-gen",
    size: u16,
    spacing: u8 = 1, // 距离场边界之外增加的字形间距。
    images: []const u8 = "font/msdf", // 相对于固定 assets 目录的图片目录。
    output: []const u8 = "src/zon/font.zon",
};

// 注册生成和转换步骤，根 build 无需了解工具参数和中间文件。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) void {
    const generate = b.addSystemCommand(&.{ options.exe, "-font" });
    generate.setCwd(b.path("."));
    generate.addFileArg(b.path(options.font));
    if (options.charset) |charset| {
        generate.addArg("-charset");
        generate.addFileArg(charset);
    }
    generate.addArgs(&.{
        // 引擎着色器取 RGB 三通道的中值恢复距离，因此固定生成 MSDF。
        "-type",
        "msdf",
        "-size",
        b.fmt("{d}", .{options.size}),
        // 距离范围固定为 2 像素，与 src/internal/quad.glsl 的 vec2(2.0) 一致。
        // 使用对称距离区间，轮廓处编码为 0.5，对应着色器中的减 0.5。
        "-pxrange",
        "2",
        // 图集原点固定在左上角，后续矩形和偏移按 Y 轴向下处理。
        "-yorigin",
        "top",
        "-outerpxpadding",
        // 相邻两字各留一半间距，不改变字体的 advance。
        b.fmt("{d}", .{@as(f32, @floatFromInt(options.spacing)) / 2}),
        "-json",
    });
    const source = generate.addOutputFileArg("font.json");
    generate.addArg("-imageout");
    const image = generate.addOutputFileArg("font.png");
    // 字符集可通过 @include 引入文件，每次执行都重新读取这些内容。
    generate.has_side_effects = true;

    // 输入路径保留生成依赖，输出设置直接注入转换程序，不经过命令行。
    const config = b.addOptions();
    config.addOptionPath("source", source);
    config.addOptionPath("image", image);
    config.addOption([]const u8, "output", options.output);
    config.addOption([]const u8, "images", options.images);
    const tool = b.addExecutable(.{
        .name = "zhuyu-msdf",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/msdf.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    tool.root_module.addOptions("options", config);
    tool.root_module.addAnonymousImport("text", .{
        .root_source_file = dep.path("src/text.zig"),
    });
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    // 转换会更新游戏源码和资源，每次显式执行 msdf 时都写入。
    run.has_side_effects = true;
    b.step("msdf", "Generate MSDF font").dependOn(&run.step);
}

// 读取构建注入的设置，生成图片资源和引擎使用的 ZON 字体描述。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const options = @import("options");
    const cwd = std.Io.Dir.cwd();
    const imageDir = try std.fs.path.join(gpa, &.{ "assets", options.images });
    try cwd.createDirPath(io, imageDir);
    if (std.fs.path.dirname(options.output)) |dir| {
        try cwd.createDirPath(io, dir);
    }
    const content = try cwd.readFileAlloc(io, options.source, gpa, .unlimited);
    const image = try writeImage(io, gpa, .{
        .image = options.image,
        .images = options.images,
    });
    const json = try std.json.parseFromSlice(Font, gpa, content, .{});
    const font = try convert(gpa, json.value, image);
    const file = try cwd.createFile(io, options.output, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.zon.stringify.serialize(font, .{}, &writer.interface);
    try writer.interface.flush();
}

// 将图片区域及基线坐标转换为引擎统一的字体描述。
fn convert(
    gpa: std.mem.Allocator,
    source: Font,
    image: [:0]const u8,
) !text.Font {
    const size = source.atlas.size;
    const chars = try gpa.alloc(text.Char, source.glyphs.len);
    for (chars, source.glyphs) |*char, glyph| {
        const bounds = glyph.atlasBounds;
        const plane = glyph.planeBounds;
        char.* = .{
            .id = glyph.unicode,
            .advance = glyph.advance,
            .rect = .{
                .min = .{ .x = bounds.left, .y = bounds.top },
                .size = .{
                    .x = bounds.right - bounds.left,
                    .y = bounds.bottom - bounds.top,
                },
            },
            .offset = .{
                .x = plane.left * size,
                .y = (-source.metrics.ascender + plane.top) * size,
            },
        };
    }
    sortChars(chars);

    return .{
        .size = size,
        .lineHeight = source.metrics.lineHeight * size,
        .imageSize = .{
            .x = @floatFromInt(source.atlas.width),
            .y = @floatFromInt(source.atlas.height),
        },
        .images = try gpa.dupe([:0]const u8, &.{image}),
        .pages = try gpa.dupe(text.Page, &.{.{
            .min = chars[0].id,
            .max = chars[chars.len - 1].id,
            .chars = chars,
        }}),
    };
}

// 图片写入只需要源图集和资源内的目标目录。
const ImageOptions = struct {
    image: []const u8,
    images: []const u8,
};

// 以图片内容生成文件名，字体描述直接引用生成后的资源路径。
fn writeImage(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: ImageOptions,
) ![:0]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.image,
        gpa,
        .unlimited,
    );
    // 最终文件内容相同时保持名称不变。
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest[0..8].*, .lower);
    const name = try std.fmt.allocPrint(gpa, "font.{s}.png", .{hash});
    const resource = try std.fs.path.join(gpa, &.{ options.images, name });
    const outputPath = try std.fs.path.join(gpa, &.{ "assets", resource });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = outputPath,
        .data = bytes,
    });

    std.mem.replaceScalar(u8, resource, '\\', '/');
    return gpa.dupeSentinel(u8, resource, 0);
}

// 引擎在每页内按字符编号二分查找。
fn sortChars(chars: []text.Char) void {
    std.mem.sortUnstable(text.Char, chars, {}, struct {
        fn lessThan(_: void, a: text.Char, b: text.Char) bool {
            return a.id < b.id;
        }
    }.lessThan);
}

// 官方生成器的 JSON 输入格式，输出类型直接使用 text 模块。
const Font = struct {
    atlas: Atlas,
    metrics: Metrics,
    glyphs: []const Glyph,
    kerning: []const std.json.Value = &.{},
};

const Atlas = struct {
    type: []const u8,
    distanceRange: u32 = 0,
    distanceRangeMiddle: u32 = 0,
    size: f32,
    width: u32,
    height: u32,
    yOrigin: []const u8,
};

const Metrics = struct {
    emSize: f32,
    lineHeight: f32,
    ascender: f32,
    descender: f32,
    underlineY: f32,
    underlineThickness: f32,
};

const Glyph = struct {
    unicode: u32,
    advance: f32,
    planeBounds: Rect = .{},
    atlasBounds: Rect = .{},
};

const Rect = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
};
