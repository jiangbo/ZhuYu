const std = @import("std");
const options = @import("options");

const assets = @import("assets.zig");
const math = @import("math.zig");
const graphics = @import("graphics.zig");
const batch = @import("batch.zig");
const memory = @import("internal/memory.zig");

const Image = graphics.Image;
const Vector2 = math.Vector2;
const Rect = math.Rect;
const Color = graphics.Color;
pub const String = []const u8;
const system = @import("internal/font.zig");
// 编译时选定查找实现，排版与绘制共用同一个检索入口。
const font = switch (options.font) {
    .bitmap, .msdf => static,
    .system => system,
};

var fontScale: f32 = undefined;
var fontSize: f32 = undefined; // 当前字体的逻辑基准字号。

pub const Option = struct {
    offset: Vector2 = .zero, // 文字位置偏移
    scale: Vector2 = .one, // 基于默认字号的缩放
    color: Color = .white, // 文字的颜色
    max: f32 = std.math.floatMax(f32), // 最大宽度，超过换行
    spacing: f32 = 0, // 文字间的间距
    anchor: ?Vector2 = null, // 锚点

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
    draw(memory.format(&buffer, fmt, args), pos, o);
}

const Utf8View = std.unicode.Utf8View;

// 文字布局：本次排版尺寸，没画完时 next 是下一段起点。
pub const Layout = struct {
    size: Vector2, // 本次排版尺寸
    next: ?usize, // 下一段起点，完整画完时为 null
};

// 绘制完整文字，宽度超出 option.max 换行，高度不限。
pub fn draw(text: String, position: Vector2, option: Option) void {
    _ = drawAt(text, position, option);
}

// 把文字画进矩形：宽度超出换行，高度超出停止，
// 没画完时 next 是剩余文字的起点。
pub fn drawIn(text: String, rect: Rect, option: Option) Layout {
    if (text.len == 0) return .{ .size = .zero, .next = null };

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

        // 测量和绘制共用字形度量，动态字体首次查找时生成并缓存。
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

        if (!render) continue;

        if (glyph.rect.size.x > 0 and glyph.rect.size.y > 0) {
            const charPos = drawPos.add(glyph.rect.min.mul(scale));
            batch.drawImage(glyph.image, charPos, .{
                .size = glyph.rect.size.mul(scale),
                .color = option.color,
            });
        }
        graphics.stats.text += 1;
    }

    return .{ .size = .xy(maxWidth, line * height), .next = next };
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
    return .square(size / (fontSize * fontScale));
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

// 构建时选定初始化方法，沿用对应实现的参数签名。
pub const init = switch (options.font) {
    .bitmap => static.init,
    .msdf => static.initMsdf,
    .system => dynamic.init,
};

// 动态字体管理自己的初始化、字号更新和资源释放。
pub const dynamic = struct {
    // 初始化系统字体，并缓存基准字号和默认绘制缩放。
    fn init(option: system.Option) void {
        system.init(option);
        fontSize = option.size;
        fontScale = 1;
    }

    pub const resize = font.resize;
    pub const deinit = font.deinit;
};

// 预生成字体直接借用有序数组，不建立运行时哈希索引。
pub const static = struct {
    // 普通位图字体的初始化配置。
    pub const InitOption = struct {
        filter: graphics.Filter = .nearest, // 位图字体的采样方式。
        size: ?f32 = null, // 默认显示字号，为 null 时使用生成字号。
    };

    // MSDF 字体的初始化配置，采样固定为线性。
    pub const MsdfOption = struct { size: ?f32 = null };

    pub const Font = struct {
        size: f32,
        lineHeight: f32,
        imageSize: Vector2,
        images: []const [:0]const u8,
        pages: []const Page,
    };

    pub const Page = struct { min: u32, max: u32, chars: []const Char };
    pub const Char = struct { id: u32, rect: math.Rect, offset: Vector2, advance: f32 };
    const Entry = struct { page: usize, char: *const Char };

    var lineHeight: f32 = undefined; // 基准字号对应的逻辑行高。
    var data: static.Font = undefined;
    var images: [8]Image = undefined;
    var invalidGlyph: Entry = undefined;

    // 加载图集，并在初始化时缓存默认显示字号的缩放比例。
    fn init(zon: static.Font, option: InitOption) void {
        std.debug.assert(zon.images.len == zon.pages.len);
        std.debug.assert(zon.images.len <= images.len);
        data = zon;
        fontSize = zon.size;
        static.lineHeight = zon.lineHeight;

        if (assets.getImage(assets.id(data.images[0])) == null) {
            assets.loadAtlas(.{
                .imagePaths = data.images,
                .size = data.imageSize,
                .images = &.{},
            }, option.filter);
        }

        const sampler = assets.sampler.get(option.filter);
        for (data.images, 0..) |path, i| {
            const image = assets.getImage(assets.id(path)).?;
            const current = assets.view.get(image.view).sampler;
            std.debug.assert(current.id == sampler.id);
            images[i] = image;
        }
        invalidGlyph = searchGlyph('?').?;
        fontScale = (option.size orelse zon.size) / zon.size;
    }

    // 加载 MSDF 字体，指定默认显示字号并使用线性采样。
    fn initMsdf(zon: static.Font, option: MsdfOption) void {
        const sk = @import("sokol");
        const shader = @import("shader");

        static.init(zon, .{ .filter = .linear, .size = option.size });
        const desc = shader.msdfShaderDesc(sk.gfx.queryBackend());
        const pipeline = batch.createPipeline(desc);
        for (images[0..data.images.len]) |image| {
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
        for (data.pages, 0..) |page, i| {
            if (code < page.min or code > page.max) continue;
            const index = std.sort.binarySearch(Char, page.chars, code, struct {
                fn compare(a: u32, b: Char) std.math.Order {
                    return std.math.order(a, b.id);
                }
            }.compare);
            if (index) |c| return .{ .page = i, .char = &page.chars[c] };
            break;
        }
        return null;
    }
};
