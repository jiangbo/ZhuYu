//! 跨平台系统字体：按需生成字形，并缓存到图集。
//! 绘制时按当前视口选择的字号生成缺失的字形。
const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const memory = @import("memory.zig");
const assets = @import("../assets.zig");
const batch = @import("../batch.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const window = @import("../window.zig");

pub const Option = struct {
    family: [:0]const u8 = "sans-serif",
    weight: u16 = 400, // 字重，400 对应常规，500 对应中等。
    size: f32 = 18, // 逻辑字号，生成时按当前视口像素比例放大。
};

// 平台接口使用像素度量，公共层统一换算为逻辑单位。
const Metrics = extern struct { ascent: f32, descent: f32, height: f32 };
// 单个码位的字形度量；矩形相对基线，使用像素单位，不含透明边框。
const Char = extern struct { rect: math.Rect, advance: f32 };

// 平台实现只负责系统字体和 RGBA 生成，不管理缓存或图集。
const platform = switch (builtin.os.tag) {
    .emscripten => web,
    else => unsupported,
};

// 四层图集共用资源，只记录当前层的装箱位置。
const Atlas = struct {
    texture: sk.gfx.Image,
    view: sk.gfx.View,
    upload: sk.gfx.Buffer,
    offset: usize = 0, // 每个字形独占一段上传区域，避免同帧写入覆盖。
    frame: u64, // 当前上传批次所属的帧。
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
    const size = @ceil(baseSize * window.scale.maxAxis());
    std.debug.assert(size >= 1 and size <= 256);
    if (size == pixelSize) return;

    // 按字号预留常用容量，实际字形超出时再按需扩容。
    const len: usize = @intFromFloat((size + 2) * (size + 2) * 4);
    if (pixels.len < len) pixels = memory.allocator.realloc(pixels, len);
    clear();
    pixelSize = size;
    std.log.info("font size: {d} px", .{pixelSize});
    metrics = platform.resize(pixelSize);
    lineHeight = metrics.height * baseSize / pixelSize;
}

// 销毁字体图集及其上传缓冲，并清空字形索引。
fn clear() void {
    if (atlas) |state| {
        sk.gfx.destroyView(state.view);
        sk.gfx.destroyImage(state.texture);
        sk.gfx.destroyBuffer(state.upload);
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
        .sampler = assets.sampler.nearest,
        .layer = @floatFromInt(state.layer),
        .offset = .xy(@floatFromInt(state.x), @floatFromInt(state.y)),
        .size = size,
    };

    // 各层共用上传缓冲，每个字形使用独立的上传区域。
    const left, const top = .{ state.x - 1, state.y - 1 };
    const copyWidth, const copyHeight = .{ width + 2, height + 2 };
    const len: usize = @intCast(copyWidth * copyHeight * 4);
    sk.gfx.writeBufferTransient(.{
        .src = .{ .data = sk.gfx.asRange(pixels[0..len]) },
        .dst = .{ .buffer = state.upload, .offset = state.offset },
    });
    batch.imageUpdates.append(memory.allocator.raw, .{
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
    }) catch memory.oom();
    state.offset += len;
    state.x += copyWidth;
    state.rowHeight = @max(state.rowHeight, height);
    return image;
}

// 创建四层纹理数组及共用的上传缓冲，返回唯一的图集状态。
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
    const width = sk.gfx.queryImageWidth(texture);
    const height = sk.gfx.queryImageHeight(texture);
    const uploadBuffer = sk.gfx.makeBuffer(.{
        .size = @intCast(width * height * 4),
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
        .upload = uploadBuffer,
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
        if (zhu_font_open(option.family, option.weight) != 0)
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
