const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const text = @import("text").static;
const fontChars = @import("chars.zig");

// 游戏配置字体生成，路径以游戏项目为起点。
pub const Options = struct {
    font: []const u8,
    input: ?[]const u8 = null, // 文件或目录，按内容收集 UTF-8 文本，默认 ASCII。
    exe: []const u8 = "msdf-atlas-gen",
    size: u16,
    maxSize: u32 = 1024, // 单页自动取尺寸，分页后每页使用此宽高。
    spacing: u8 = 1, // 距离场边界之外增加的字形间距。
    images: []const u8 = "font", // 相对于 assets 的专用输出目录，生成前清空。
    output: []const u8 = "src/zon/font.zon",
};

// 注册转换程序，收集并排序字符，分页由工具按尺寸上限决定。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) !void {
    if (options.maxSize == 0) return error.InvalidFontMaxSize;
    const codes = try fontChars.read(b, options.input);
    // 路径先按游戏项目解析，其余配置保持调用方的字段名。
    var toolOptions = options;
    toolOptions.font = try b.root.joinString(b.allocator, options.font);
    const config = b.addOptions();
    config.addOption(Options, "config", toolOptions);
    config.addOption([]const u21, "codes", codes);
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
    run.addFileInput(b.path(options.font));
    _ = run.addOutputDirectoryArg2("msdf", .{});
    run.has_side_effects = true;
    b.step("msdf", "Generate MSDF font").dependOn(&run.step);
}

// 字表与中间文件保存在构建缓存内，不混入最终资源目录。
const Source = struct {
    charset: []const u8,
    json: []const u8,
    image: []const u8,
};

// 运行期间共用的资源与配置，在 main 中初始化后只读传递。
const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: std.Io.Dir,
    options: @TypeOf(@import("options").config),
    codes: []const u21,
    cacheDir: []const u8,
};

// 主流程：整体试排、选择单页或分页、保存最终字体资源。
pub fn main(init: std.process.Init) !void {
    const ctx = try createContext(init);

    // 全部字符先只计算排布，得到一张图集所需的实际宽高。
    const all = try writeSource(&ctx, "all", ctx.codes);
    const layout = (try generate(&ctx, all, null, false)).?;

    var pages: []Page = undefined;
    if (layout.atlas.width <= ctx.options.maxSize and
        layout.atlas.height <= ctx.options.maxSize)
    {
        // 一张能放下，直接使用生成器算出的尺寸生成图片。
        pages = try buildSinglePage(&ctx, all);
    } else {
        // 先生成 ASCII 图集，再按剩余面积估算各页字符数。
        const estimates = try estimatePageCounts(&ctx, layout);
        // 每页从估算数量开始逐个增减，确认边界后生成图片。
        pages = try buildPages(&ctx, estimates);
    }

    // 全部图片生成成功后，再更新资源图片和 ZON 字体描述。
    try saveFont(&ctx, pages);
    std.log.info("generated {} font page(s), size={}x{}", .{
        pages.len, pages[0].font.atlas.width, pages[0].font.atlas.height,
    });
}

// 初始化公共资源与配置，并准备构建缓存目录。
fn createContext(init: std.process.Init) !Context {
    const config = @import("options");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const ctx = Context{
        .io = init.io,
        .gpa = init.arena.allocator(),
        .cwd = std.Io.Dir.cwd(),
        .options = config.config,
        .codes = config.codes,
        .cacheDir = args[1],
    };
    try ctx.cwd.createDirPath(ctx.io, ctx.cacheDir);
    return ctx;
}

// 单页保留自动尺寸，统一返回与多页相同的数据结构。
fn buildSinglePage(ctx: *const Context, source: Source) ![]Page {
    const font = (try generate(ctx, source, null, true)).?;
    return ctx.gpa.dupe(Page, &.{.{ .source = source, .font = font }});
}

// 更新最终图片目录，合并各页字形并写入引擎使用的字体描述。
fn saveFont(ctx: *const Context, pages: []const Page) !void {
    const imageDir = try std.fs.path.join(ctx.gpa, &.{ "assets", ctx.options.images });
    // 与 BMFont 共用字体目录，成功生成后移除之前的图片。
    try ctx.cwd.deleteTree(ctx.io, imageDir);
    try ctx.cwd.createDirPath(ctx.io, imageDir);
    if (std.fs.path.dirname(ctx.options.output)) |dir| {
        try ctx.cwd.createDirPath(ctx.io, dir);
    }
    const font = try convert(ctx, pages);
    const file = try ctx.cwd.createFile(ctx.io, ctx.options.output, .{});
    defer file.close(ctx.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    try std.zon.stringify.serialize(font, .{}, &writer.interface);
    try writer.interface.flush();
}

// 图片与字形描述成对保存，避免两组数组的顺序不一致。
const Page = struct { source: Source, font: Font };

// ASCII 使用实际生成的图集面积，剩余容量按非 ASCII 字符数估算。
fn estimatePageCounts(ctx: *const Context, layout: Font) ![]const usize {
    var asciiCount: usize = 0;
    while (asciiCount < ctx.codes.len and ctx.codes[asciiCount] < 128) {
        asciiCount += 1;
    }
    const asciiSource = try writeSource(ctx, "ascii", ctx.codes[0..asciiCount]);
    const asciiFont = (try generate(ctx, asciiSource, null, true)).?;
    const pageArea = @as(u64, ctx.options.maxSize) * ctx.options.maxSize;
    // ASCII 本身超过一页时先预留整页，再由实际试装确定边界。
    const asciiImageArea = @as(u64, asciiFont.atlas.width) * asciiFont.atlas.height;
    const asciiArea = @min(pageArea, asciiImageArea);
    const totalArea = @as(u64, layout.atlas.width) * layout.atlas.height;
    // 预估最多取 8 页，是否超限仍由实际试装决定。
    const pageCount: usize = @intCast(@min(8, @max(2, try std.math.divCeil(
        u64,
        totalArea,
        pageArea,
    ))));
    const otherArea = pageArea * pageCount - asciiArea;
    const otherCount = ctx.codes.len - asciiCount;
    const estimates = try ctx.gpa.alloc(usize, pageCount);
    var previous: usize = 0;
    for (estimates, 0..) |*estimate, i| {
        const area = pageArea * (i + 1) - asciiArea;
        const count = @as(f64, @floatFromInt(otherCount)) *
            @as(f64, @floatFromInt(area)) /
            @as(f64, @floatFromInt(otherArea));
        const end = asciiCount + @as(usize, @intFromFloat(@round(count)));
        estimate.* = end - previous;
        previous = end;
    }

    return estimates;
}

// 按码位顺序逐页试装，字符边界确认后再渲染当前页。
fn buildPages(ctx: *const Context, estimates: []const usize) ![]Page {
    var pages: std.ArrayList(Page) = .empty;
    var start: usize = 0;
    while (start < ctx.codes.len) {
        const index = pages.items.len;
        if (index == 8) {
            std.log.err("font needs more than 8 pages, increase maxSize", .{});
            return error.TooManyFontPages;
        }
        const codes = ctx.codes[start..];
        const estimate = estimates[@min(index, estimates.len - 1)];
        const initial = @min(codes.len, @max(1, estimate));
        const name = try std.fmt.allocPrint(ctx.gpa, "{d}", .{index});
        const source = try writeSource(ctx, name, codes[0..initial]);
        const count = try fitPage(ctx, source, codes, initial);
        // 最后一次试装可能留下超限字表，渲染前写回已确认的字符范围。
        try writeCharset(ctx, source.charset, codes[0..count]);
        const font = (try generate(ctx, source, ctx.options.maxSize, true)).?;
        try pages.append(ctx.gpa, .{ .source = source, .font = font });
        std.log.info("font page {}: estimated {} chars, packed {}", .{
            index + 1, initial, count,
        });
        start += count;
    }
    return pages.toOwnedSlice(ctx.gpa);
}

// 从估算数量开始：放得下就逐个增加，否则逐个减少到首次成功。
fn fitPage(
    ctx: *const Context,
    source: Source,
    codes: []const u21,
    initial: usize,
) !usize {
    var count = initial;
    if (try fitsPage(ctx, source, codes[0..count])) {
        while (count < codes.len) : (count += 1) {
            if (!try fitsPage(ctx, source, codes[0 .. count + 1])) break;
        }
        return count;
    }
    while (count > 1) {
        count -= 1;
        if (try fitsPage(ctx, source, codes[0..count])) return count;
    }
    std.log.err("font glyph U+{X} does not fit, increase maxSize", .{codes[0]});
    return error.FontGlyphTooLarge;
}

// 试装只运行生成器的实际排布，不编码距离场图片。
fn fitsPage(ctx: *const Context, source: Source, codes: []const u21) !bool {
    try writeCharset(ctx, source.charset, codes);
    return try generate(ctx, source, ctx.options.maxSize, false) != null;
}

// 字表和中间文件统一放在缓存目录，名称由当前处理阶段决定。
fn writeSource(ctx: *const Context, name: []const u8, codes: []const u21) !Source {
    const base = try std.fs.path.join(ctx.gpa, &.{ ctx.cacheDir, name });
    const source = Source{
        .charset = try std.fmt.allocPrint(ctx.gpa, "{s}.txt", .{base}),
        .json = try std.fmt.allocPrint(ctx.gpa, "{s}.json", .{base}),
        .image = try std.fmt.allocPrint(ctx.gpa, "{s}.png", .{base}),
    };
    try writeCharset(ctx, source.charset, codes);
    return source;
}

// 字符集使用带引号和转义的 UTF-8 字符串，供生成器直接读取。
fn writeCharset(ctx: *const Context, path: []const u8, codes: []const u21) !void {
    var content: std.ArrayList(u8) = .empty;
    for (codes) |code| {
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(code, &buffer);
        try content.appendSlice(ctx.gpa, buffer[0..len]);
    }
    try ctx.cwd.writeFile(ctx.io, .{
        .sub_path = path,
        .data = try std.json.Stringify.valueAlloc(ctx.gpa, content.items, .{}),
    });
}

// 只计算尺寸时不输出图片；固定尺寸装不下时返回 null，其他错误直接失败。
fn generate(
    ctx: *const Context,
    source: Source,
    imageSize: ?u32,
    render: bool,
) !?Font {
    var args: std.ArrayList([]const u8) = .empty;
    const glyphSize = try std.fmt.allocPrint(ctx.gpa, "{d}", .{ctx.options.size});
    const padding = try std.fmt.allocPrint(ctx.gpa, "{d}", .{
        @as(f32, @floatFromInt(ctx.options.spacing)) / 2,
    });
    // 距离范围、原点和中值编码与引擎着色器一致。
    // zig fmt: off
    try args.appendSlice(ctx.gpa, &.{ ctx.options.exe,
        "-font", ctx.options.font,
        "-charset", source.charset,
        "-type", "msdf",
        "-size", glyphSize,
        "-pxrange", "2",
        "-yorigin", "top",
        "-outerpxpadding", padding,
        "-json", source.json,
    });
    // zig fmt: on
    if (imageSize) |size| {
        const dim = try std.fmt.allocPrint(ctx.gpa, "{d}", .{size});
        try args.appendSlice(ctx.gpa, &.{ "-dimensions", dim, dim });
    }
    if (render) try args.appendSlice(ctx.gpa, &.{ "-imageout", source.image });
    const result = try std.process.run(ctx.gpa, ctx.io, .{ .argv = args.items });
    if (!result.term.success()) {
        if (imageSize != null and
            std.mem.indexOf(u8, result.stderr, "Could not fit ") != null)
        {
            return null;
        }
        std.log.err("font page {s}: {s} {f}: {s}", .{
            std.fs.path.basename(source.charset), ctx.options.exe,
            result.term,                          result.stderr,
        });
        return error.FontCommandFailed;
    }
    const content = try ctx.cwd.readFileAlloc(
        ctx.io,
        source.json,
        ctx.gpa,
        .unlimited,
    );
    const json = try std.json.parseFromSlice(Font, ctx.gpa, content, .{});
    if (json.value.glyphs.len == 0) {
        std.log.err("font page {s} has no glyphs", .{
            std.fs.path.basename(source.charset),
        });
        return error.EmptyFontPage;
    }
    return json.value;
}

// 各页共用字体参数，字符保存实际前进距离，图片和字形页按相同顺序保存。
fn convert(ctx: *const Context, pages: []const Page) !text.Font {
    const images = try ctx.gpa.alloc([:0]const u8, pages.len);
    const fontPages = try ctx.gpa.alloc(text.Page, pages.len);
    for (pages, images, fontPages) |output, *image, *page| {
        const source = output.font;
        const size = source.atlas.size;
        std.debug.assert(size == pages[0].font.atlas.size);
        std.debug.assert(source.metrics.lineHeight ==
            pages[0].font.metrics.lineHeight);
        const chars = try ctx.gpa.alloc(text.Char, source.glyphs.len);
        for (chars, source.glyphs) |*char, glyph| {
            const bounds = glyph.atlasBounds;
            const plane = glyph.planeBounds;
            char.* = .{
                .id = glyph.unicode,
                .advance = glyph.advance * size,
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
        image.* = try writeImage(ctx, output.source.image);
        page.* = .{
            .min = chars[0].id,
            .max = chars[chars.len - 1].id,
            .chars = chars,
        };
    }
    return .{
        .size = pages[0].font.atlas.size,
        .lineHeight = pages[0].font.metrics.lineHeight * pages[0].font.atlas.size,
        .imageSize = .{
            .x = @floatFromInt(pages[0].font.atlas.width),
            .y = @floatFromInt(pages[0].font.atlas.height),
        },
        .images = images,
        .pages = fontPages,
    };
}

// 以图片内容生成文件名，字体描述直接引用生成后的资源路径。
fn writeImage(ctx: *const Context, image: []const u8) ![:0]const u8 {
    const bytes = try ctx.cwd.readFileAlloc(
        ctx.io,
        image,
        ctx.gpa,
        .unlimited,
    );
    // 最终文件内容相同时保持名称不变。
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest[0..8].*, .lower);
    const name = try std.fmt.allocPrint(ctx.gpa, "{s}.png", .{hash});
    const resource = try std.fs.path.join(ctx.gpa, &.{ ctx.options.images, name });
    const outputPath = try std.fs.path.join(ctx.gpa, &.{ "assets", resource });
    try ctx.cwd.writeFile(ctx.io, .{
        .sub_path = outputPath,
        .data = bytes,
    });

    std.mem.replaceScalar(u8, resource, '\\', '/');
    return ctx.gpa.dupeSentinel(u8, resource, 0);
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
