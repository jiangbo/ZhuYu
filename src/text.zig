const std = @import("std");
const options = @import("options");
const sk = @import("sokol");

const platform = @import("internal/platform.zig");
const assets = @import("assets.zig");
const zhu = @import("zhu.zig");
const graphics = @import("graphics.zig");
const batch = @import("batch.zig");
const window = @import("window.zig");

const Image = graphics.Image;
const Vector2 = zhu.Vector2;
const Rect = zhu.Rect;
const Color = graphics.Color;
pub const String = []const u8;

// 编译时选择内部字形查询实现。
const font = switch (options.font) {
    .static => static,
    .system, .custom => assets.glyph,
};

var fontScale: f32 = 1;

// 文字绘制是否默认对齐字形顶点到目标像素。
pub var snap: bool = false;

pub const Option = struct {
    offset: Vector2 = .zero, // 文字位置偏移
    scale: Vector2 = .one, // 基于默认字号的缩放
    color: Color = .white, // 文字的颜色
    snap: ?bool = null, // null 使用 text 的默认设置。
    max: f32 = std.math.floatMax(f32), // 最大宽度，超过换行
    spacing: f32 = 0, // 文字间的间距
    anchor: ?Vector2 = null, // 锚点
    count: usize = std.math.maxInt(usize), // 显示字符数，换行不计

    pub fn with(
        self: Option,
        comptime field: std.meta.FieldEnum(Option),
        value: @FieldType(Option, @tagName(field)),
    ) Option {
        var result = self;
        @field(result, @tagName(field)) = value;
        return result;
    }
};

pub const Line = struct { text: String, option: Option = .{} };
pub const Lines = []const Line;

// 数值绘制复用格式化文字的缓冲区。
pub fn drawNumber(number: anytype, pos: Vector2, option: Option) void {
    drawFmt("{d}", .{number}, pos, option);
}

pub fn drawFmt(comptime fmt: String, args: anytype, pos: Vector2, o: Option) void {
    var buffer: [1024]u8 = undefined;
    draw(zhu.format(&buffer, fmt, args), pos, o);
}

const Utf8View = std.unicode.Utf8View;

// 文字布局不受 option.count 影响，next 是下一页的 UTF-8 字节位置。
pub const Layout = struct {
    size: Vector2 = .zero, // 本次排版尺寸
    count: usize = 0, // 本页字符总数，换行不计。
    next: ?usize = null, // 下一页起点，最后一页为 null。
};

// 绘制文字，宽度超出 option.max 换行，高度不限。
pub fn draw(text: String, position: Vector2, option: Option) void {
    _ = drawAt(text, position, option);
}

// 把文字画进矩形：宽度超出换行，高度超出停止，
// count 控制本页显示进度，返回的 next 始终指向下一页。
pub fn drawIn(text: String, rect: Rect, option: Option) Layout {
    if (text.len == 0) return .{};

    // 矩形宽度和 option.max 同时限制本次排版。
    const opt = option.with(.max, @min(rect.size.x, option.max));
    var position = rect.min;
    if (opt.anchor) |anchor| {
        // anchor 只对齐矩形内实际排下的当前页。
        const size = layout(text, position, rect.size.y, opt, false).size;
        position = position.add(rect.size.sub(size).mul(anchor));
    }
    return layout(text, position, rect.size.y, opt, true);
}

// 无高度限制的点对齐绘制：文字的 anchor 点压在 position 上。
fn drawAt(text: String, position: Vector2, option: Option) Vector2 {
    if (text.len == 0) return .zero;

    var pos = position;
    if (option.anchor) |anchor| {
        pos = pos.sub(measure(text, option).mul(anchor));
    }
    return layout(text, pos, null, option, true).size;
}

// 统一计算测量和绘制；heightLimit 是与 position 无关的相对高度。
fn layout(
    text: String,
    position: Vector2,
    heightLimit: ?f32,
    option: Option,
    comptime render: bool,
) Layout {
    const scale = option.scale.scale(fontScale);
    const height = font.lineHeight * scale.y;
    const maxHeight = heightLimit orelse std.math.floatMax(f32);
    std.debug.assert(height <= maxHeight);

    // offset 只移动最终位置，不参与宽高、分页和 anchor 计算。
    const start = position.add(option.offset);

    var next: ?usize = null;
    var count: usize = 0;
    var width: f32, var line: f32 = .{ 0, 1 };
    var maxWidth: f32 = 0;
    var iterator = Utf8View.initUnchecked(text).iterator();
    while (iterator.i < text.len) {
        const offset = iterator.i;
        const code = iterator.nextCodepoint().?;

        if (code == '\n') {
            // 换行导致分页时，页边界已经完成换行，直接消费它。
            if ((line + 1) * height > maxHeight) {
                if (iterator.i < text.len) next = iterator.i;
                break;
            }
            width, line = .{ 0, line + 1 };
            continue;
        }

        // 测量和绘制共用字形度量，字形查询按字体模式分派。
        const glyph = font.findGlyph(code);
        const advance = glyph.advance * scale.x;
        if (width > 0 and width + option.spacing + advance > option.max) {
            // 换行后新行的行底超出高度，当前字符留给下一段
            if ((line + 1) * height > maxHeight) {
                next = offset;
                break;
            }
            width, line = .{ 0, line + 1 };
        } else if (width > 0) width += option.spacing;

        const drawPos = start.add(.xy(width, (line - 1) * height));
        width += advance;
        maxWidth = @max(maxWidth, width);

        count += 1;
        if (!render or count > option.count) continue;

        if (glyph.rect.size.x > 0 and glyph.rect.size.y > 0) {
            const charPos = drawPos.add(glyph.rect.min.mul(scale));
            batch.drawImage(glyph.image, charPos, .{
                .size = glyph.rect.size.mul(scale),
                .color = option.color,
                .snap = option.snap orelse snap,
            });
        }
        assets.frameStats.text += 1;
    }

    return .{ .size = .xy(maxWidth, line * height), .count = count, .next = next };
}

pub fn drawLines(lines: Lines, position: Vector2, spacing: f32) void {
    var y: f32 = 0;
    for (lines) |line| {
        const size = drawAt(line.text, position.addY(y), line.option);
        y += size.y + spacing;
    }
}

pub fn measure(text: String, option: Option) Vector2 {
    if (text.len == 0) return .zero;
    return layout(text, .zero, null, option, false).size;
}

pub fn measureLines(lines: Lines, spacing: f32) Vector2 {
    var size: Vector2 = .zero;
    for (lines, 0..) |line, i| {
        const lineSize = measure(line.text, line.option);
        size.x = @max(size.x, lineSize.x);
        size.y += lineSize.y;
        if (i + 1 < lines.len) size.y += spacing;
    }
    return size;
}

pub fn lineHeight(option: Option) f32 {
    return font.lineHeight * fontScale * option.scale.y;
}

pub fn sizeToScale(size: f32) Vector2 {
    return .all(size / (font.size * fontScale));
}

pub fn computeTextCount(text: String) usize {
    var iterator = Utf8View.initUnchecked(text).iterator();
    var total: usize = 0;
    while (iterator.nextCodepoint()) |code| {
        if (code != '\n') total += 1;
    }
    return total;
}

pub fn encodeUtf8(buffer: []u8, unicode: []const u21) []u8 {
    var len: usize = 0;
    for (unicode) |code| {
        // 将单个 unicode 编码为 utf8
        len += std.unicode.utf8Encode(code, buffer[len..]) //
            catch std.debug.panic("illegal unicode: {}", .{code});
    }
    return buffer[0..len];
}

pub fn nextIndex(str: []const u8, index: usize) usize {
    const next = std.unicode.utf8ByteSequenceLength(str[index]);
    return index + (next catch unreachable);
}

// 预生成字体直接借用有序数组，不建立运行时哈希索引。
pub const static = if (options.font == .static) struct {
    // 普通位图字体的初始化配置。
    pub const InitOption = struct {
        filter: graphics.Filter = .nearest, // 位图字体的采样方式。
        size: ?f32 = null, // 默认显示字号，为 null 时使用生成字号。
    };

    // MSDF 字体的初始化配置，采样固定为线性。
    pub const MsdfOption = struct { size: ?f32 = null };

    pub const Font = struct {
        name: []const u8, // 生成源记录的字体名称。
        size: f32,
        lineHeight: f32,
        imageSize: Vector2,
        images: []const [:0]const u8,
        pages: []const Page,
    };

    pub const Page = struct { min: u32, max: u32, chars: []const Char };
    pub const Char = struct { id: u32, rect: zhu.Rect, offset: Vector2, advance: f32 };
    const Entry = struct { page: usize, char: *const Char };

    pub var size: f32 = undefined;
    pub var lineHeight: f32 = undefined;
    var pages: []const Page = undefined;
    var images: [8]Image = undefined;
    var invalidGlyph: Entry = undefined;

    // 加载图集，并在初始化时缓存默认显示字号的缩放比例。
    pub fn initBitmap(zon: static.Font, option: InitOption) void {
        std.debug.assert(zon.images.len == zon.pages.len);
        std.debug.assert(zon.images.len <= images.len);
        static.size, static.lineHeight = .{ zon.size, zon.lineHeight };
        pages = zon.pages;

        if (assets.getImage(assets.id(zon.images[0])) == null) {
            _ = assets.atlas.load(.{
                .imagePaths = zon.images,
                .size = zon.imageSize,
                .images = &.{},
            }, .{ .filter = option.filter });
        }

        for (zon.images, 0..) |path, i| {
            const image = assets.getImage(assets.id(path)).?;
            std.debug.assert(image.filter == option.filter);
            images[i] = image;
        }
        invalidGlyph = searchGlyph('?').?;
        fontScale = (option.size orelse zon.size) / zon.size;
        var count: usize = 0; // 静态字库的字形数量和容量相同。
        for (zon.pages) |page| count += page.chars.len;
        assets.fontStats = .{
            .name = zon.name,
            .size = zon.size * fontScale,
            .count = count,
            .capacity = count,
        };
    }

    // 加载 MSDF 字体，指定默认显示字号并使用线性采样。
    pub fn initMsdf(zon: static.Font, option: MsdfOption) void {
        const shader = @import("shader");

        static.initBitmap(zon, .{ .filter = .linear, .size = option.size });
        const desc = shader.msdfShaderDesc(sk.gfx.queryBackend());
        const pipeline = graphics.createPipeline(desc);
        for (images[0..zon.images.len]) |image| {
            assets.view.getPtr(image.view).pipeline = pipeline;
        }
    }

    // 页范围筛选后在字符数组中二分查找，缺字使用预生成的问号。
    fn findGlyph(code: u32) graphics.Glyph {
        const entry = searchGlyph(code) orelse invalidGlyph;
        const char = entry.char;
        return .{
            .image = images[entry.page].sub(char.rect),
            .rect = .init(char.offset, char.rect.size),
            .advance = char.advance,
        };
    }

    // 字符记录一直借用原数组，检索不分配内存。
    fn searchGlyph(code: u32) ?Entry {
        for (pages, 0..) |page, i| {
            if (code < page.min or code > page.max) continue;
            const index = std.sort.binarySearch(Char, page.chars, code, struct {
                fn compare(a: u32, b: Char) std.math.Order {
                    return std.math.order(a, b.id);
                }
            }.compare);
            if (index) |c| return .{ .page = i, .char = &page.chars[c] };
            // 各页码位范围可能重叠，未找到时继续检查后续页。
        }
        return null;
    }
} else struct {};

// 系统字体来源，平台对象和窗口缩放策略仅在系统模式存在。
pub const system = if (options.font == .system) struct {
    pub const Buffer = assets.glyph.Buffer;
    pub const Option = struct {
        family: [:0]const u8 = "sans-serif",
        weight: enum { normal, bold } = .normal, // 普通或加粗字重。
        size: f32 = 18, // 逻辑字号，生成时按当前视口像素比例放大。
        resizeDelay: f32 = 0.4, // 窗口停止变化后等待多少秒再刷新字形。
    };

    // 平台接口使用像素度量，公共层统一换算为逻辑单位。
    pub const Metrics = extern struct { ascent: f32, descent: f32, height: f32 };
    // 单个码位的字形度量；矩形相对基线，使用像素单位，不含透明边框。
    pub const Char = extern struct { rect: zhu.Rect, advance: f32 };

    const backend = platform.backend.font;
    var nameBuffer: [1024]u8 = undefined; // 持有平台查询到的 UTF-8 名称。
    var opened: bool = false; // 系统字体是否已经初始化。
    var option: system.Option = undefined; // 保存初始化配置。
    var resizeWait: ?f32 = null; // 没有等待中的缩放时为 null。
    var pixelSize: f32 = undefined; // 当前字形生成字号。
    var metrics: system.Metrics = undefined; // 基线和行高度量。

    // 初始化所选平台的系统字体和度量，不提前生成字形像素。
    // 公共像素缓冲和字形缓存由 assets.glyph 管理，平台内部内存由平台管理。
    // atlas.layer 为首个字形层，后续层均可写。
    pub fn init(atlas: Image, config: system.Option) void {
        std.debug.assert(!opened);
        std.debug.assert(config.resizeDelay >= 0);
        // 名称由平台填入；没有取得名称时显示请求的字体族。
        const len = backend.open(config, &nameBuffer);
        opened = true;
        option = config;
        resizeWait = null;
        pixelSize = 0;
        assets.glyph.init(atlas, config.size, createGlyph);
        assets.fontStats.name = if (len > 0) nameBuffer[0..len] else config.family;
        resize();
    }

    // 每帧在游戏绘制前更新，连续缩放时重新开始等待。
    pub fn update(delta: f32) void {
        if (!opened) return;
        if (window.resized) resizeWait = option.resizeDelay;
        if (resizeWait) |wait| {
            if (wait <= 0 or (!window.resized and wait <= delta)) {
                resizeWait = null;
                resize();
            } else if (!window.resized) {
                resizeWait = wait - delta;
            }
        }
    }

    // 仅在像素字号变化时清除旧字形并更新字体度量。
    pub fn resize() void {
        std.debug.assert(opened);
        // 生成字号不低于逻辑字号，缩放倍率不超过 1 时复用字形缓存。
        const size = @max(option.size, option.size * window.scale.maxAxis());
        std.debug.assert(size >= 1 and size <= 256);
        if (size == pixelSize) return;

        // 按字号预留常用容量，实际字形超出时再按需扩容。
        const side = @ceil(size) + 2; // 只有像素缓冲区尺寸需要整数。
        pixelSize = size;
        std.log.info("font size: {d} px", .{pixelSize});
        metrics = backend.resize(pixelSize);
        const height = metrics.height * option.size / pixelSize;
        assets.glyph.lineHeight = height;
        assets.glyph.resize(@intFromFloat(side));
        assets.fontStats.size = pixelSize;
    }

    // 释放字体缓存和系统字体。
    pub fn deinit() void {
        if (!opened) return;
        backend.close();
        assets.fontStats = .{};
        opened = false;
    }

    // 图集保留实际像素，绘制区域和前进距离归一到逻辑基准字号。
    pub fn createGlyph(code: u32, buffer: *system.Buffer) graphics.Glyph {
        std.debug.assert(opened);
        const char = backend.pixels(code, buffer);
        const factor = option.size / pixelSize;
        return .{
            .image = .{ .size = char.rect.size },
            .rect = .{
                .min = char.rect.min.addY(metrics.ascent).scale(factor),
                .size = char.rect.size.scale(factor),
            },
            .advance = char.advance * factor,
        };
    }
} else struct {};
