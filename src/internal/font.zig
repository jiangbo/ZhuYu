//! 跨平台系统字体：按需生成字形，并缓存到图集。
//! 绘制时按当前视口选择的字号生成缺失的字形。
const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const memory = @import("memory.zig");
const assets = @import("../assets.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const window = @import("../window.zig");

pub const Option = struct {
    family: [:0]const u8 = "sans-serif",
    weight: enum { normal, bold } = .normal, // 普通或加粗字重。
    size: f32 = 18, // 逻辑字号，生成时按当前视口像素比例放大。
};

// 平台接口使用像素度量，公共层统一换算为逻辑单位。
const Metrics = extern struct { ascent: f32, descent: f32, height: f32 };
// 单个码位的字形度量；矩形相对基线，使用像素单位，不含透明边框。
const Char = extern struct { rect: math.Rect, advance: f32 };

// 平台实现只负责系统字体和 RGBA 生成，不管理缓存或图集。
const platform = switch (builtin.os.tag) {
    .emscripten => web,
    .linux => if (builtin.abi.isAndroid()) unsupported else linux,
    else => unsupported,
};

// 四层图集共用资源，记录上传位置及当前层的装箱位置。
const Atlas = struct {
    texture: sk.gfx.Image,
    view: sk.gfx.View,
    upload: sk.gfx.Buffer, // 通过 GPU 模块创建和释放的上传缓冲。
    offset: usize = 0, // 本帧下一个字形的上传偏移。
    frame: u64, // 上传缓冲当前所属的帧。
    layer: i32 = 0,
    x: i32 = 1,
    y: i32 = 1,
    rowHeight: i32 = 0,
};

pub var lineHeight: f32 = undefined; // 基准字号对应的逻辑行高。
var opened: bool = false; // 系统字体是否已经初始化。
var baseSize: f32 = undefined;
var pixelSize: f32 = undefined; // 当前视口对应的字形生成字号。
var metrics: Metrics = undefined; // 固定字号对应的基线和行高度量。
var atlas: ?Atlas = null; // 首个可见字形出现时创建四层纹理数组。
var glyphs: std.AutoHashMapUnmanaged(u32, graphics.Glyph) = undefined;
var pixels: []u8 = undefined; // 单线程生成字形时复用，容量不足才扩容。

// 初始化所选平台的系统字体和度量，不提前生成字形像素。
pub fn init(option: Option) void {
    std.debug.assert(!opened);
    glyphs = .empty;
    pixels = &.{};
    platform.open(option);
    opened = true;
    baseSize = option.size;
    pixelSize = 0;
    resize();
}

// 仅在像素字号变化时清除旧字形并更新字体度量。
pub fn resize() void {
    std.debug.assert(opened);
    // 保留小数字号，最小生成 1 像素，避免窗口过小时字号无效。
    const size = @max(1, baseSize * window.scale.maxAxis());
    std.debug.assert(size >= 1 and size <= 256);
    if (size == pixelSize) return;

    // 按字号预留常用容量，实际字形超出时再按需扩容。
    const side = @ceil(size) + 2; // 只有像素缓冲区尺寸需要整数。
    const len: usize = @intFromFloat(side * side * 4);
    if (pixels.len < len) pixels = memory.allocator.realloc(pixels, len);
    clear();
    pixelSize = size;
    std.log.info("font size: {d} px", .{pixelSize});
    metrics = platform.resize(pixelSize);
    lineHeight = metrics.height * baseSize / pixelSize;
}

// 销毁字体图集，通过 GPU 模块释放上传缓冲，并清空字形索引。
fn clear() void {
    if (atlas) |state| {
        assets.view.destroy(state.view);
        sk.gfx.destroyImage(state.texture);
        assets.gpu.destroyBuffer(state.upload);
    }
    atlas = null;
    glyphs.clearRetainingCapacity();
}

// 由游戏清理阶段调用，释放图集、字形索引和系统字体。
pub fn deinit() void {
    if (!opened) return;
    clear();
    glyphs.deinit(memory.allocator.raw);
    memory.allocator.free(pixels);
    platform.close();
    opened = false;
}

// 按码位查找固定字号的字形，缓存未命中时生成。
pub fn findGlyph(code: u32) graphics.Glyph {
    std.debug.assert(opened);
    if (glyphs.get(code)) |glyph| return glyph;
    if (atlas) |*state| {
        const frame = window.frameCount();
        if (state.frame != frame) {
            state.frame = frame;
            state.offset = 0;
        }
    }
    return createGlyph(code);
}

// 图集保留实际像素，绘制区域和前进距离归一到逻辑基准字号。
fn createGlyph(code: u32) graphics.Glyph {
    // 容量不足时只返回字形信息，不写像素，等待扩容后再次调用。
    var char = platform.pixels(code, pixels);
    const size = char.rect.size;
    const len: usize = @intFromFloat((size.x + 2) * (size.y + 2) * 4);
    if (len > pixels.len) {
        pixels = memory.allocator.realloc(pixels, len);
        char = platform.pixels(code, pixels);
        // 按重试返回的尺寸确认缓冲区已经足够。
        const next = char.rect.size;
        const needed: usize = @intFromFloat((next.x + 2) * (next.y + 2) * 4);
        std.debug.assert(needed == pixels.len);
    }
    const factor = baseSize / pixelSize;
    const glyph = graphics.Glyph{
        .image = addImage(char.rect.size),
        .rect = .{
            .min = char.rect.min.addY(metrics.ascent).scale(factor),
            .size = char.rect.size.scale(factor),
        },
        .advance = char.advance * factor,
    };
    glyphs.put(memory.allocator.raw, code, glyph) catch memory.oom();
    return glyph;
}

// 每个字形包含一像素透明边框，当前层装满后使用下一层。
fn addImage(size: math.Vector2) graphics.Image {
    // 空字形只参与排版，不占用图集和上传缓冲。
    if (size.x == 0 or size.y == 0) return .{};

    const width: i32 = @intFromFloat(size.x);
    const height: i32 = @intFromFloat(size.y);

    const state = if (atlas) |*value| value else addAtlas();
    const atlasWidth = sk.gfx.queryImageWidth(state.texture);
    const atlasHeight = sk.gfx.queryImageHeight(state.texture);
    if (state.x + width + 1 > atlasWidth) {
        state.x = 1;
        state.y += state.rowHeight + 2;
        state.rowHeight = 0;
    }
    if (state.y + height + 1 > atlasHeight) {
        if (state.layer + 1 == sk.gfx.queryImageNumSlices(state.texture))
            @panic("font atlas layer limit exceeded");
        state.layer += 1;
        state.x, state.y = .{ 1, 1 };
        state.rowHeight = 0;
    }
    const image = graphics.Image{
        .view = state.view,
        .layer = @floatFromInt(state.layer),
        .offset = .xy(@floatFromInt(state.x), @floatFromInt(state.y)),
        .size = size,
    };

    // 每个字形使用独立的上传区域，复制记录由 GPU 模块统一提交。
    const left, const top = .{ state.x - 1, state.y - 1 };
    const copyWidth, const copyHeight = .{ width + 2, height + 2 };
    const len: usize = @intCast(copyWidth * copyHeight * 4);
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
            .image = state.texture,
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

// 创建四层纹理数组，通过 GPU 模块创建共用的上传缓冲。
fn addAtlas() *Atlas {
    const texture = sk.gfx.makeImage(.{
        .width = 1024,
        .height = 1024,
        .type = .ARRAY,
        .num_slices = 4,
        .usage = .{ .copy_dst = true },
        .label = "system font atlas",
    });
    const view = sk.gfx.makeView(.{ .texture = .{ .image = texture } });
    assets.view.put(view, .{ .sampler = assets.sampler.nearest });
    const upload = assets.gpu.makeBuffer(.{
        .size = 1024 * 1024 * 4,
        .usage = .{
            .staging_buffer = true,
            .write_transient = true,
            .copy_src = true,
        },
        .label = "system font upload",
    });
    atlas = .{
        .texture = texture,
        .view = view,
        .upload = upload,
        .frame = window.frameCount(),
    };
    return &atlas.?;
}

// Web 平台模块：直接使用公共度量结构，封装 JS 调用和状态码。
const web = struct {
    extern fn zhu_font_open([*:0]const u8, u32) c_int;
    extern fn zhu_font_close() void;
    extern fn zhu_font_metrics(f32, *Metrics) void;
    extern fn zhu_font_pixels(u32, *Char, [*]u8, u32) c_int;

    // 打开浏览器字体，宿主创建失败时直接终止。
    fn open(option: Option) void {
        const weight: u32 = switch (option.weight) {
            .normal => 400,
            .bold => 700,
        };
        if (zhu_font_open(option.family, weight) != 0)
            @panic("font unavailable");
    }

    // 释放浏览器保存的字体和画布引用。
    fn close() void {
        zhu_font_close();
    }

    // 设置像素字号并读取字体度量，后续像素生成沿用此字号。
    fn resize(size: f32) Metrics {
        var result: Metrics = undefined;
        zhu_font_metrics(size, &result);
        return result;
    }

    // 容量不足时只返回字形信息，不写像素，等待扩容后再次调用。
    fn pixels(code: u32, buffer: []u8) Char {
        var char: Char = undefined;
        _ = zhu_font_pixels(code, &char, buffer.ptr, @intCast(buffer.len));
        return char;
    }
};

// Linux 平台直接使用系统库查找字体，并生成字形像素。
const linux = struct {
    const c = @import("font/linux.zig");
    // FreeType 的 26.6 定点数有 6 位小数，除以 64 得到点数或像素数。
    const fixedScale: f32 = 64;

    var library: c.FT_Library = null; // 当前后端独占的 FreeType 实例。
    var face: c.FT_Face = null; // 只打开匹配到的一个字体，不做缺字回退。

    // 按字体名称、字重和中文偏好匹配一个字体，找不到或打不开就终止。
    fn open(option: Option) void {
        const config = c.FcInitLoadConfigAndFonts() orelse
            @panic("font config unavailable");
        defer c.FcConfigDestroy(config);
        if (c.FT_Init_FreeType(&library) != 0) @panic("font library unavailable");

        const pattern = c.FcPatternCreate() orelse memory.oom();
        defer c.FcPatternDestroy(pattern);
        if (c.FcPatternAddString(pattern, "family", option.family.ptr) == 0)
            memory.oom();
        // 默认按简体中文匹配，避免优先选到日文字形。
        if (c.FcPatternAddString(pattern, "lang", "zh-cn") == 0) memory.oom();
        // Fontconfig 的普通和加粗字重分别是 80、200。
        const weight: c_int = switch (option.weight) {
            .normal => 80,
            .bold => 200,
        };
        if (c.FcPatternAddInteger(pattern, "weight", weight) == 0) memory.oom();
        // 0 对应 FcMatchPattern，应用查询条件的配置规则。
        if (c.FcConfigSubstitute(config, pattern, 0) == 0) memory.oom();
        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        const matched = c.FcFontMatch(config, pattern, &result) orelse
            @panic("font unavailable");
        defer c.FcPatternDestroy(matched);
        if (result != 0) @panic("font unavailable");

        var path: [*c]u8 = null;
        var index: c_int = 0;
        if (c.FcPatternGetString(matched, "file", 0, &path) != 0 or
            c.FcPatternGetInteger(matched, "index", 0, &index) != 0)
            @panic("font file unavailable");
        if (c.FT_New_Face(library, @ptrCast(path), index, &face) != 0)
            @panic("font open failed");
        // FT_ENCODING_UNICODE 使用四字节标签 'unic'。
        if (c.FT_Select_Charmap(face, 0x756e6963) != 0)
            @panic("font unicode unavailable");
    }

    // 关闭唯一的字体及其 FreeType 实例。
    fn close() void {
        _ = c.FT_Done_Face(face);
        face = null;
        _ = c.FT_Done_FreeType(library);
        library = null;
    }

    // 以 1/64 点设置字号，并读取基线和行高度量。
    fn resize(size: f32) Metrics {
        // 点制规定每英寸 72 点；选择 72 DPI，使点数直接对应目标像素数。
        const dpi: c_uint = 72;
        const charSize: c_long = @intFromFloat(@round(size * fixedScale));
        if (c.FT_Set_Char_Size(face, 0, charSize, dpi, dpi) != 0)
            @panic("font size unavailable");
        const faceMetrics = face.*.size.*.metrics;
        const height = @as(f32, @floatFromInt(faceMetrics.height)) / fixedScale;
        return .{
            .ascent = @as(f32, @floatFromInt(faceMetrics.ascender)) / fixedScale,
            .descent = -@as(f32, @floatFromInt(faceMetrics.descender)) / fixedScale,
            .height = @max(size, height),
        };
    }

    // 使用选定字体生成白色 RGBA，缺字暂用该字体的缺字字形。
    fn pixels(code: u32, buffer: []u8) Char {
        const glyph = c.FT_Get_Char_Index(face, code);
        // FT_LOAD_RENDER 在加载时直接生成位图。
        if (c.FT_Load_Glyph(face, glyph, 1 << 2) != 0)
            @panic("font glyph unavailable");

        const slot = face.*.glyph.*;
        const bitmap = slot.bitmap;
        const char = Char{
            .rect = .{
                .min = .{
                    .x = @floatFromInt(slot.bitmap_left),
                    .y = -@as(f32, @floatFromInt(slot.bitmap_top)),
                },
                .size = .xy(@floatFromInt(bitmap.width), @floatFromInt(bitmap.rows)),
            },
            .advance = @as(f32, @floatFromInt(slot.advance.x)) / fixedScale,
        };
        if (bitmap.width == 0 or bitmap.rows == 0) return char;

        const width: usize = bitmap.width;
        const height: usize = bitmap.rows;
        const stride = (width + 2) * 4;
        const len = stride * (height + 2);
        if (buffer.len < len) return char;
        // 2 是灰度位图，1 是单色位图。
        if (bitmap.pixel_mode != 2 and bitmap.pixel_mode != 1)
            @panic("unsupported font pixel mode");

        @memset(buffer[0..len], 0);
        const pitch: usize = @abs(bitmap.pitch);
        for (0..height) |y| {
            const row = if (bitmap.pitch < 0) height - 1 - y else y;
            const source = bitmap.buffer + row * pitch;
            for (0..width) |x| {
                const alpha: u8 = if (bitmap.pixel_mode == 2)
                    source[x]
                else if (source[x / 8] & (@as(u8, 128) >> @intCast(x % 8)) != 0)
                    255
                else
                    0;
                const offset = (y + 1) * stride + (x + 1) * 4;
                @memset(buffer[offset..][0..3], 255);
                buffer[offset + 3] = alpha;
            }
        }
        return char;
    }
};

// 尚未实现的平台模块：只有实际调用系统字体接口时才终止。
const unsupported = struct {
    // 当前平台尚未实现字体打开。
    fn open(_: Option) void {
        @panic("system font is not implemented on this platform");
    }

    // 当前平台尚未实现字体关闭。
    fn close() void {
        @panic("system font is not implemented on this platform");
    }

    // 当前平台尚未实现字号设置和字体度量。
    fn resize(_: f32) Metrics {
        @panic("system font is not implemented on this platform");
    }

    // 当前平台尚未实现字形像素生成。
    fn pixels(_: u32, _: []u8) Char {
        @panic("system font is not implemented on this platform");
    }
};
