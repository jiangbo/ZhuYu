const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const text = @import("text");
const fontChars = @import("chars.zig");

// BMFont 使用字体文件及其 Windows 字体名称，原文可来自文件或目录。
pub const Options = struct {
    font: []const u8, // 相对于客户端项目的字体文件路径。
    face: []const u8,
    input: ?[]const u8 = null, // 文件或目录，按内容收集 UTF-8 文本，默认 ASCII。
    exe: []const u8 = "bmfont64",
    size: u16,
    spacing: u8 = 1, // 图集中字形之间的留白，不是排版字距。
    antialias: bool = true,
    images: []const u8 = "font", // 相对于 assets 的专用输出目录，生成前清空。
    output: []const u8 = "src/zon/font.zon",
};

// 配置由 build 写入缓存，命令直接生成 PNG 和引擎字体描述。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) !void {
    const generate = b.addSystemCommand(&.{ options.exe, "-c" });
    generate.setCwd(b.path("."));
    generate.addFileArg(createConfig(b, options));
    generate.addFileInput(b.path(options.font));
    if (options.input) |input| {
        generate.addArg("-t");
        generate.addFileArg(try createCharset(b, input));
    }
    generate.addArg("-o");
    const source = generate.addOutputFileArg("font.fnt");
    // 描述文件和多页图集由同一次命令生成，每次显式执行都更新。
    generate.has_side_effects = true;

    addConvertStep(b, dep, source, .{
        .images = options.images,
        .output = options.output,
        .name = "bmfont",
    });
}

// BMFont 和 fontbm 共用二进制描述转换，生成相同的引擎资源格式。
pub fn addConvertStep(
    b: *Build,
    dep: *Dependency,
    source: Build.LazyPath,
    options: struct {
        images: []const u8,
        output: []const u8,
        name: []const u8,
    },
) void {
    // 描述文件路径保留生成依赖，输出设置通过模块注入转换程序。
    const config = b.addOptions();
    config.addOptionPath("source", source);
    config.addOption([]const u8, "output", options.output);
    config.addOption([]const u8, "images", options.images);
    const tool = b.addExecutable(.{
        .name = b.fmt("zhuyu-{s}", .{options.name}),
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/bmfont.zig"),
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
    // 转换会更新游戏源码和资源，每次显式生成时都写入。
    run.has_side_effects = true;
    b.step(options.name, "Generate bitmap font").dependOn(&run.step);
}

// BMFont 用 BOM 识别 UTF-8，字表编码与缓存文件由工具自身负责。
fn createCharset(b: *Build, input: []const u8) !Build.LazyPath {
    const codes = try fontChars.read(b, input);
    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(b.allocator, "\xef\xbb\xbf");
    for (codes) |code| {
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(code, &buffer);
        try content.appendSlice(b.allocator, buffer[0..len]);
    }
    return b.addWriteFiles().add("bmfont.txt", content.items);
}

// 固定生成 BMFont v3 二进制描述和 PNG，匹配字体解析和引擎采样方式。
// fontDescFormat=2 选择二进制描述，供下方按 v3 块结构读取。
// RGB 固定为白色，字形覆盖率存入 alpha，绘制时再乘文字颜色。
fn createConfig(b: *Build, options: Options) Build.LazyPath {
    const fontPath = b.root.joinString(b.allocator, options.font) catch
        @panic("Out of memory");
    return b.addWriteFiles().add("font.bmfc", b.fmt(
        \\fileVersion=1
        \\fontName={s}
        \\fontFile={s}
        \\charSet=0
        \\fontSize=-{d}
        \\aa=1
        \\scaleH=100
        \\useSmoothing={d}
        \\isBold=0
        \\isItalic=0
        \\useUnicode=1
        \\disableBoxChars=1
        \\outputInvalidCharGlyph=0
        \\dontIncludeKerningPairs=1
        \\useHinting=1
        \\renderFromOutline=0
        \\useClearType=0
        \\autoFitNumPages=0
        \\paddingDown=0
        \\paddingUp=0
        \\paddingRight=0
        \\paddingLeft=0
        \\spacingHoriz={d}
        \\spacingVert={d}
        \\useFixedHeight=0
        \\forceZero=0
        \\outWidth=1024
        \\outHeight=1024
        \\outBitDepth=32
        \\fontDescFormat=2
        \\fourChnlPacked=0
        \\textureFormat=png
        \\textureCompression=0
        \\alphaChnl=0
        \\redChnl=4
        \\greenChnl=4
        \\blueChnl=4
        \\invA=0
        \\invR=0
        \\invG=0
        \\invB=0
        \\outlineThickness=0
        \\chars=32-126
        \\
    , .{
        options.face,                    fontPath,        options.size,
        @intFromBool(options.antialias), options.spacing, options.spacing,
    }));
}

// 读取构建注入的设置，生成图片资源和引擎使用的 ZON 字体描述。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const options = @import("options");
    const cwd = std.Io.Dir.cwd();
    const imageDir = try std.fs.path.join(gpa, &.{ "assets", options.images });
    // 字体输出目录由生成工具独占，整目录重建以移除旧页面。
    try cwd.deleteTree(io, imageDir);
    try cwd.createDirPath(io, imageDir);
    if (std.fs.path.dirname(options.output)) |dir| {
        try cwd.createDirPath(io, dir);
    }

    const content = try std.Io.Dir.cwd().readFileAlloc( //
        io, options.source, gpa, .unlimited);
    const source = parse(gpa, content);

    const pageCount = source.pages.len;
    const lists = try gpa.alloc(std.ArrayList(text.Char), pageCount);
    for (lists) |*list| list.* = .empty;

    const size = source.info.fontSize;
    // 所有页面共用 ASCII 字宽表，未收录的控制字符不占宽度。
    const advance = try gpa.alloc(f32, 128);
    @memset(advance, 0);
    for (source.chars) |char| {
        if (char.id < 128) {
            advance[char.id] = @as(f32, @floatFromInt(char.xAdvance)) /
                @as(f32, @floatFromInt(size));
        }
        try lists[char.page].append(gpa, .{
            .id = char.id,
            .rect = .{
                .min = .{
                    .x = @floatFromInt(char.x),
                    .y = @floatFromInt(char.y),
                },
                .size = .{
                    .x = @floatFromInt(char.width),
                    .y = @floatFromInt(char.height),
                },
            },
            .offset = .{
                .x = @floatFromInt(char.xOffset),
                .y = @floatFromInt(char.yOffset),
            },
        });
    }

    const images = try gpa.alloc([:0]const u8, pageCount);
    const pages = try gpa.alloc(text.Page, pageCount);
    for (pages, source.pages, lists, 0..) |*page, image, *chars, i| {
        // 图片名带内容哈希，ZON 引用相对于资源目录的路径。
        const path = try std.fs.path.join(gpa, &.{
            std.fs.path.dirname(options.source).?, image,
        });
        const bytes = try cwd.readFileAlloc(io, path, gpa, .unlimited);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hash = std.fmt.bytesToHex(digest[0..8].*, .lower);
        const name = try std.fmt.allocPrint(gpa, "{s}.png", .{hash});
        const destination = try std.fs.path.join(gpa, &.{ imageDir, name });
        try cwd.writeFile(io, .{
            .sub_path = destination,
            .data = bytes,
        });
        const resource = try std.fs.path.join(gpa, &.{ options.images, name });
        std.mem.replaceScalar(u8, resource, '\\', '/');
        images[i] = try gpa.dupeSentinel(u8, resource, 0);
        sortChars(chars.items);
        page.* = .{
            .min = chars.items[0].id,
            .max = chars.items[chars.items.len - 1].id,
            .chars = chars.items,
        };
    }

    const result = text.Font{
        .size = @floatFromInt(size),
        .lineHeight = @floatFromInt(source.common.lineHeight),
        .advance = advance,
        .imageSize = .{
            .x = @floatFromInt(source.common.scaleW),
            .y = @floatFromInt(source.common.scaleH),
        },
        .images = images,
        .pages = pages,
    };
    try writeZon(io, options.output, result);
}

// 二进制字段按 BMFont v3 的块顺序读取，内存由进程 arena 管理。
pub fn parse(gpa: std.mem.Allocator, data: []const u8) Font {
    arena = gpa;
    var reader: std.Io.Reader = .fixed(data);
    doParse(&reader) catch unreachable;
    return rawFont;
}

const BlockTag = enum(u8) { none, info, common, page, char, kerning };

// 校验文件标识与版本，再读取字体、页面、字符和字距块。
fn doParse(reader: *std.Io.Reader) !void {
    if (!std.mem.eql(u8, try reader.take(3), "BMF")) {
        return error.badHeader;
    }

    if (try reader.takeByte() != 3) {
        return error.incompatibleVersion;
    }

    try parseInfo(reader, try parseSize(reader, .info));
    try parseCommon(reader, try parseSize(reader, .common));
    try parsePage(reader, try parseSize(reader, .page));
    try parseChar(reader, try parseSize(reader, .char));
    try parseKerningPairs(reader, try parseSize(reader, .kerning));
}

// 检查当前块类型，文件结束表示没有可选的末尾字距块。
fn parseSize(reader: *std.Io.Reader, tag: BlockTag) !usize {
    const actualInt = reader.takeByte() catch |e| {
        if (e == error.EndOfStream) return 0;
        return e;
    };
    const actual: BlockTag = @fromBackingInt(@intCast(actualInt));
    if (actual != tag) return error.unexpectedBlock;
    return @intCast(try reader.takeInt(i32, .little));
}

var rawFont: Font = undefined;
var arena: std.mem.Allocator = undefined;

// 保留字体生成信息，负字号转换为用于比例计算的正数。
fn parseInfo(reader: *std.Io.Reader, _: usize) !void {
    rawFont.info = .{
        .fontSize = @intCast(@abs(try reader.takeInt(i16, .little))),
        .bitField = try reader.takeByte(),
        .charSet = try reader.takeByte(),
        .stretchH = try reader.takeInt(u16, .little),
        .aa = try reader.takeByte(),
        .paddingUp = try reader.takeByte(),
        .paddingRight = try reader.takeByte(),
        .paddingDown = try reader.takeByte(),
        .paddingLeft = try reader.takeByte(),
        .spacingHoriz = try reader.takeByte(),
        .spacingVert = try reader.takeByte(),
        .outline = try reader.takeByte(),
    };
    rawFont.info.name = try readString(reader);
}

// 读取所有页面共用的行高、图片尺寸和通道描述。
fn parseCommon(reader: *std.Io.Reader, _: usize) !void {
    rawFont.common = .{
        .lineHeight = try reader.takeInt(u16, .little),
        .base = try reader.takeInt(u16, .little),
        .scaleW = try reader.takeInt(u16, .little),
        .scaleH = try reader.takeInt(u16, .little),
        .pages = try reader.takeInt(u16, .little),
        .bitField = try reader.takeByte(),
        .alphaChnl = try reader.takeByte(),
        .redChnl = try reader.takeByte(),
        .greenChnl = try reader.takeByte(),
        .blueChnl = try reader.takeByte(),
    };
}

// 页面名称按文件中的顺序保存，对应字符里的 page 索引。
fn parsePage(reader: *std.Io.Reader, size: usize) !void {
    const end = reader.seek + size;
    var pages: std.ArrayList([]const u8) = .empty;
    while (reader.seek < end) {
        try pages.append(arena, try readString(reader));
    }
    rawFont.pages = try pages.toOwnedSlice(arena);
}

// 每个字符固定占用 20 字节，包含取图区域和绘制偏移。
fn parseChar(reader: *std.Io.Reader, size: usize) !void {
    const len: usize = @intCast(@divExact(size, 20));

    const chars = try arena.alloc(Char, len);
    for (chars) |*char| {
        char.* = Char{
            .id = try reader.takeInt(u32, .little),
            .x = try reader.takeInt(u16, .little),
            .y = try reader.takeInt(u16, .little),
            .width = try reader.takeInt(u16, .little),
            .height = try reader.takeInt(u16, .little),
            .xOffset = try reader.takeInt(i16, .little),
            .yOffset = try reader.takeInt(i16, .little),
            .xAdvance = try reader.takeInt(i16, .little),
            .page = try reader.takeByte(),
            .chnl = try reader.takeByte(),
        };
    }
    rawFont.chars = chars;
}

// 读取原文件的字距对，输出格式沿用引擎现有的字符间距规则。
fn parseKerningPairs(reader: *std.Io.Reader, size: usize) !void {
    const pairs: usize = @intCast(@divExact(size, 10));

    const kerningPairs = try arena.alloc(KerningPair, pairs);
    for (kerningPairs) |*pair| {
        pair.* = KerningPair{
            .first = try reader.takeInt(u32, .little),
            .second = try reader.takeInt(u32, .little),
            .amount = try reader.takeInt(i16, .little),
        };
    }
    rawFont.kerningPairs = kerningPairs;
}

// BMFont 的字体名和页面名称都由零字节结束。
fn readString(reader: *std.Io.Reader) ![]const u8 {
    return try reader.takeSentinel(0);
}

// 引擎在每页内按字符编号二分查找。
fn sortChars(chars: []text.Char) void {
    std.mem.sortUnstable(text.Char, chars, {}, struct {
        fn lessThan(_: void, a: text.Char, b: text.Char) bool {
            return a.id < b.id;
        }
    }.lessThan);
}

// 字体描述写入客户端指定的 ZON 文件。
fn writeZon(io: std.Io, name: []const u8, value: text.Font) !void {
    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.zon.stringify.serialize(value, .{}, &writer.interface);
    try writer.interface.flush();
}

// BMFont 二进制输入格式，输出类型直接使用 text 模块。
pub const Font = struct {
    info: Info,
    common: Common,
    pages: []const []const u8,
    chars: []const Char,
    kerningPairs: []const KerningPair,
};

pub const Info = struct {
    fontSize: i16,
    bitField: u8,
    charSet: u8,
    stretchH: u16,
    aa: u8,
    paddingUp: u8,
    paddingRight: u8,
    paddingDown: u8,
    paddingLeft: u8,
    spacingHoriz: u8,
    spacingVert: u8,
    outline: u8,
    name: []const u8 = &.{},
};

pub const Common = struct {
    lineHeight: u16,
    base: u16,
    scaleW: u16,
    scaleH: u16,
    pages: u16,
    bitField: u8,
    alphaChnl: u8,
    redChnl: u8,
    greenChnl: u8,
    blueChnl: u8,
};

pub const Char = struct {
    id: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    xOffset: i16,
    yOffset: i16,
    xAdvance: i16,
    page: u8,
    chnl: u8,
};

pub const KerningPair = struct { first: u32, second: u32, amount: i16 };
