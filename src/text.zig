const std = @import("std");
const options = @import("options");
const sk = @import("sokol");

const assets = @import("assets.zig");
const zhu = @import("zhu.zig");
const graphics = @import("graphics.zig");
const batch = @import("batch.zig");
const memory = @import("internal/memory.zig");
const window = @import("window.zig");

const Image = graphics.Image;
const Vector2 = zhu.Vector2;
const Rect = zhu.Rect;
const Color = graphics.Color;
pub const String = []const u8;
// 编译时选定查找实现，排版与绘制共用同一个检索入口。
const font = switch (options.font) {
    .bitmap, .msdf => static,
    .system => dynamic,
};

var fontScale: f32 = undefined;
var fontSize: f32 = undefined; // 当前字体的逻辑基准字号。

// 调试面板使用的字体和字库统计。
pub const Stats = struct {
    name: []const u8 = "",
    size: f32 = 0,
    count: usize = 0,
    capacity: usize = 0,
};

// 字体变化时更新，调试面板直接读取，不在每帧查询时计算。
pub var stats: Stats = .{};
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
                .snap = option.snap orelse snap,
            });
        }
        assets.frameStats.text += 1;
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
    return .all(size / (fontSize * fontScale));
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

        for (data.images, 0..) |path, i| {
            const image = assets.getImage(assets.id(path)).?;
            std.debug.assert(image.filter == option.filter);
            images[i] = image;
        }
        invalidGlyph = searchGlyph('?').?;
        fontScale = (option.size orelse zon.size) / zon.size;
        var count: usize = 0; // 静态字库的字形数量和容量相同。
        for (zon.pages) |page| count += page.chars.len;
        stats = .{
            .name = zon.name,
            .size = fontSize * fontScale,
            .count = count,
            .capacity = count,
        };
    }

    // 加载 MSDF 字体，指定默认显示字号并使用线性采样。
    fn initMsdf(zon: static.Font, option: MsdfOption) void {
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
            // 各页码位范围可能重叠，未找到时继续检查后续页。
        }
        return null;
    }
};

// 动态字体统一管理字形缓存、图集和平台字体的生命周期。
pub const dynamic = struct {
    pub const Option = struct {
        atlas: graphics.Image, // layer 为首个字形层，后续层均可写。
        family: [:0]const u8 = "sans-serif",
        weight: enum { normal, bold } = .normal, // 普通或加粗字重。
        size: f32 = 18, // 逻辑字号，生成时按当前视口像素比例放大。
        filter: graphics.Filter = .nearest, // 字形图片的默认采样方式。
        resizeDelay: f32 = 0.4, // 窗口停止变化后等待多少秒再刷新字形。
    };

    var nameBuffer: [1024]u8 = undefined; // 持有平台查询到的 UTF-8 名称。

    // 平台接口使用像素度量，公共层统一换算为逻辑单位。
    pub const Metrics = extern struct { ascent: f32, descent: f32, height: f32 };
    // 单个码位的字形度量；矩形相对基线，使用像素单位，不含透明边框。
    pub const Char = extern struct { rect: zhu.Rect, advance: f32 };

    // 直接使用当前平台的字体接口。
    const backend = window.platform.font;

    // 字形上传及装箱状态，不持有图片纹理。
    const GlyphState = struct {
        upload: sk.gfx.Buffer, // 通过 GPU 模块创建和释放的上传缓冲。
        offset: usize = 0, // 本帧下一个字形的上传偏移。
        layer: i32 = 0,
        x: i32 = 1,
        y: i32 = 1,
        rowHeight: i32 = 0,
    };

    pub var lineHeight: f32 = undefined; // 基准字号对应的逻辑行高。
    var opened: bool = false; // 系统字体是否已经初始化。
    var fontOption: dynamic.Option = undefined; // 保存初始化配置，使用时直接读取。
    var resizeWait: ?f32 = null; // 没有等待中的缩放时为 null。
    var pixelSize: f32 = undefined; // 当前视口对应的字形生成字号。
    var metrics: Metrics = undefined; // 固定字号对应的基线和行高度量。
    var glyphState: GlyphState = undefined; // 上传缓冲按需创建并扩容。
    var glyphs: std.AutoHashMapUnmanaged(u32, graphics.Glyph) = undefined;
    var pixels: []u8 = undefined; // 单线程生成字形时复用，容量不足才扩容。

    // 初始化所选平台的系统字体和度量，不提前生成字形像素。
    pub fn init(option: dynamic.Option) void {
        std.debug.assert(!opened);
        std.debug.assert(option.resizeDelay >= 0);
        glyphs = .empty;
        pixels = &.{};
        // 名称由平台填入；没有取得名称时显示请求的字体族。
        const len = backend.open(option, &nameBuffer);
        stats.name = if (len > 0) nameBuffer[0..len] else option.family;
        opened = true;
        fontSize = option.size;
        fontOption = option;
        glyphState = .{
            .upload = .{},
            .layer = fontOption.atlas.layer,
        };
        resizeWait = null;
        fontScale = 1;
        pixelSize = 0;
        resize();
    }

    // 每帧在游戏绘制前更新，连续缩放时重新开始等待。
    pub fn update(delta: f32) void {
        if (!opened) return;
        glyphState.offset = 0;
        if (window.resized) resizeWait = fontOption.resizeDelay;
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
        // 保留小数字号，最小生成 1 像素，避免窗口过小时字号无效。
        const size = @max(1, fontSize * window.scale.maxAxis());
        std.debug.assert(size >= 1 and size <= 256);
        if (size == pixelSize) return;

        // 按字号预留常用容量，实际字形超出时再按需扩容。
        const side = @ceil(size) + 2; // 只有像素缓冲区尺寸需要整数。
        const len: usize = @intFromFloat(side * side * 4);
        if (pixels.len < len)
            pixels = memory.allocator.realloc(pixels, len) catch memory.oom();
        // 重置装箱位置，保留上传缓冲及本帧已使用的上传区域。
        glyphState.layer = fontOption.atlas.layer;
        glyphState.x, glyphState.y = .{ 1, 1 };
        glyphState.rowHeight = 0;
        glyphs.clearRetainingCapacity();
        pixelSize = size;
        std.log.info("font size: {d} px", .{pixelSize});
        metrics = backend.resize(pixelSize);
        dynamic.lineHeight = metrics.height * fontSize / pixelSize;
        // 按字号加两像素边框估算方格容量，只在缓存重建时计算。
        const texture = sk.gfx.queryViewImage(fontOption.atlas.view);
        const width: usize = @intCast(sk.gfx.queryImageWidth(texture));
        const height: usize = @intCast(sk.gfx.queryImageHeight(texture));
        const layers: usize = @intCast(sk.gfx.queryImageNumSlices(texture) -
            fontOption.atlas.layer);
        const cell: usize = @intFromFloat(side);
        stats.size = pixelSize;
        stats.count = 0;
        stats.capacity = (width / cell) * (height / cell) * layers;
    }

    // 释放字形上传缓冲、字形索引和系统字体。
    pub fn deinit() void {
        if (!opened) return;
        assets.gpu.destroyBuffer(glyphState.upload);
        glyphs.deinit(memory.allocator);
        memory.allocator.free(pixels);
        backend.close();
        stats = .{};
        opened = false;
    }

    // 按码位查找固定字号的字形，缓存未命中时生成。
    pub fn findGlyph(code: u32) graphics.Glyph {
        std.debug.assert(opened);
        if (glyphs.get(code)) |glyph| return glyph;
        // 图集尚未就绪时返回空字形，不生成像素，也不写入缓存。
        const texture = sk.gfx.queryViewImage(fontOption.atlas.view);
        if (sk.gfx.queryImageState(texture) != .VALID) {
            return .{ .image = .{}, .rect = .init(.zero, .zero), .advance = 0 };
        }
        return createGlyph(code);
    }

    // 图集保留实际像素，绘制区域和前进距离归一到逻辑基准字号。
    fn createGlyph(code: u32) graphics.Glyph {
        // 容量不足时只返回字形信息，不写像素，等待扩容后再次调用。
        var char = backend.pixels(code, pixels);
        const size = char.rect.size;
        const len: usize = @intFromFloat((size.x + 2) * (size.y + 2) * 4);
        if (len > pixels.len) {
            pixels = memory.allocator.realloc(pixels, len) catch memory.oom();
            char = backend.pixels(code, pixels);
            // 按重试返回的尺寸确认缓冲区已经足够。
            const next = char.rect.size;
            const needed: usize = @intFromFloat((next.x + 2) * (next.y + 2) * 4);
            std.debug.assert(needed == pixels.len);
        }
        const factor = fontSize / pixelSize;
        const glyph = graphics.Glyph{
            .image = addImage(char.rect.size),
            .rect = .{
                .min = char.rect.min.addY(metrics.ascent).scale(factor),
                .size = char.rect.size.scale(factor),
            },
            .advance = char.advance * factor,
        };
        glyphs.put(memory.allocator, code, glyph) catch memory.oom();
        stats.count = glyphs.count();
        return glyph;
    }

    // 每个字形包含一像素透明边框，当前层装满后使用下一层。
    fn addImage(size: zhu.Vector2) graphics.Image {
        // 空字形只参与排版，不占用图集和上传缓冲。
        if (size.x == 0 or size.y == 0) return .{};

        const width: i32 = @intFromFloat(size.x);
        const height: i32 = @intFromFloat(size.y);

        const state = &glyphState;
        const texture = sk.gfx.queryViewImage(fontOption.atlas.view);
        const atlasWidth = sk.gfx.queryImageWidth(texture);
        const atlasHeight = sk.gfx.queryImageHeight(texture);
        if (state.x + width + 1 > atlasWidth) {
            state.x = 1;
            state.y += state.rowHeight + 2;
            state.rowHeight = 0;
        }
        if (state.y + height + 1 > atlasHeight) {
            if (state.layer + 1 == sk.gfx.queryImageNumSlices(texture))
                @panic("font atlas layer limit exceeded");
            state.layer += 1;
            state.x, state.y = .{ 1, 1 };
            state.rowHeight = 0;
        }
        const image = graphics.Image{
            .view = fontOption.atlas.view,
            .layer = @intCast(state.layer),
            .filter = fontOption.filter,
            .offset = .xy(@floatFromInt(state.x), @floatFromInt(state.y)),
            .size = size,
        };

        // 每个字形使用独立的上传区域，复制记录由 GPU 模块统一提交。
        const left, const top = .{ state.x - 1, state.y - 1 };
        const copyWidth, const copyHeight = .{ width + 2, height + 2 };
        const len: usize = @intCast(copyWidth * copyHeight * 4);
        const capacity = sk.gfx.queryBufferSize(state.upload);
        if (state.offset + len > capacity) {
            // 先消费旧缓冲的复制记录，不搬迁已上传的字形数据。
            assets.gpu.uploadImageUpdates();
            assets.gpu.destroyBuffer(state.upload);
            state.upload = assets.gpu.makeBuffer(.{
                .size = @max(@max(capacity * 2, len), 64 * 1024),
                .usage = .{
                    .staging_buffer = true,
                    .write_transient = true,
                    .copy_src = true,
                },
                .label = "system font upload",
            });
            state.offset = 0;
        }
        sk.gfx.writeBufferTransient(.{
            .src = .{ .data = sk.gfx.asRange(pixels[0..len]) },
            .dst = .{ .buffer = state.upload, .offset = state.offset },
        });
        assets.gpu.addUpdate(.{
            .src = .{
                .buffer = state.upload,
                .offset = state.offset,
                .bytes_per_row = copyWidth * 4,
                .bytes_per_slice = @intCast(len),
            },
            .dst = .{
                .image = texture,
                .x = left,
                .y = top,
                .slice = state.layer,
            },
            .size = .{ .width = copyWidth, .height = copyHeight, .num_slices = 1 },
        });
        state.offset += len;
        state.x += copyWidth;
        state.rowHeight = @max(state.rowHeight, height);
        return image;
    }
};
