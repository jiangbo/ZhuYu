//! Linux 平台字体实现，构建和运行都不依赖 C 头文件。
//! FreeType 对象由库分配；这里只声明读取字段所需的结构体前缀。
const std = @import("std");

const zhu = @import("../zhu.zig");
const dynamic = @import("../text.zig").dynamic;

const Init = std.process.Init;

// 当前平台的用户数据目录，路径写入调用方缓冲区。
pub fn dataPath(info: Init, name: []const u8, buf: []u8) []const u8 {
    if (info.environ_map.get("XDG_DATA_HOME")) |base|
        return zhu.format(buf, "{s}/{s}", .{ base, name });
    const home = info.environ_map.get("HOME") orelse @panic("HOME not set");
    return zhu.format(buf, "{s}/.local/share/{s}", .{ home, name });
}

pub fn setup(_: std.mem.Allocator) void {}

// Linux 系统字体的单例状态，公共图集由 text.dynamic 管理。
pub const font = struct {
    var library: FT_Library = null; // 当前后端独占的 FreeType 实例。
    var face: FT_Face = null; // 只打开匹配到的一个字体，不做缺字回退。

    // 按字体名称、字重和中文偏好匹配一个字体，找不到或打不开就终止。
    // 返回写入的名称字节数；查询不到名称时返回零。
    pub fn open(option: dynamic.Option, nameBuffer: []u8) usize {
        const config = FcInitLoadConfigAndFonts() orelse
            @panic("font config unavailable");
        defer FcConfigDestroy(config);
        if (FT_Init_FreeType(&library) != 0) @panic("font library unavailable");

        const pattern = FcPatternCreate() orelse
            @panic("fontconfig: failed to create font pattern");
        defer FcPatternDestroy(pattern);
        if (FcPatternAddString(pattern, "family", option.family.ptr) == 0)
            @panic("fontconfig: failed to add font family");
        // 默认按简体中文匹配，避免优先选到日文字形。
        if (FcPatternAddString(pattern, "lang", "zh-cn") == 0)
            @panic("fontconfig: failed to add font language");
        // Fontconfig 的普通和加粗字重分别是 80、200。
        const weight: c_int = switch (option.weight) {
            .normal => 80,
            .bold => 200,
        };
        if (FcPatternAddInteger(pattern, "weight", weight) == 0)
            @panic("fontconfig: failed to add font weight");
        // 0 对应 FcMatchPattern，应用查询条件的配置规则。
        if (FcConfigSubstitute(config, pattern, 0) == 0)
            @panic("fontconfig: failed to apply font rules");
        FcDefaultSubstitute(pattern);

        var result: FcResult = undefined;
        const matched = FcFontMatch(config, pattern, &result) orelse
            @panic("font unavailable");
        defer FcPatternDestroy(matched);
        if (result != 0) @panic("font unavailable");

        var path: [*c]u8 = null;
        var index: c_int = 0;
        if (FcPatternGetString(matched, "file", 0, &path) != 0 or
            FcPatternGetInteger(matched, "index", 0, &index) != 0)
            @panic("font file unavailable");
        const err = FT_New_Face(library, @ptrCast(path), index, &face);
        if (err != 0) std.debug.panic(
            "freetype: failed to open font {s}, index {}, error {}",
            .{ std.mem.span(path), index, err },
        );
        // FT_ENCODING_UNICODE 使用四字节标签 'unic'。
        if (FT_Select_Charmap(face, 0x756e6963) != 0)
            @panic("font unicode unavailable");
        // 匹配结果的名称必须在释放 Fontconfig 对象前复制。
        var name: [*c]u8 = null;
        if (FcPatternGetString(matched, "family", 0, &name) != 0) return 0;
        const selected = std.mem.span(name);
        if (selected.len > nameBuffer.len) return 0;
        @memcpy(nameBuffer[0..selected.len], selected);
        return selected.len;
    }

    // 关闭唯一的字体及其 FreeType 实例。
    pub fn close() void {
        _ = FT_Done_Face(face);
        face = null;
        _ = FT_Done_FreeType(library);
        library = null;
    }

    // 以 1/64 点设置字号，并读取基线和行高度量。
    pub fn resize(size: f32) dynamic.Metrics {
        // FreeType 的 26.6 定点数有 6 位小数，换算时使用 64。
        // 点制规定每英寸 72 点；选择 72 DPI，使点数直接对应目标像素数。
        const charSize: c_long = @intFromFloat(@round(size * 64));
        if (FT_Set_Char_Size(face, 0, charSize, 72, 72) != 0)
            @panic("font size unavailable");
        const faceMetrics = face.*.size.*.metrics;
        const height = @as(f32, @floatFromInt(faceMetrics.height)) / 64;
        return .{
            .ascent = @as(f32, @floatFromInt(faceMetrics.ascender)) / 64,
            .descent = -@as(f32, @floatFromInt(faceMetrics.descender)) / 64,
            .height = @max(size, height),
        };
    }

    // 使用选定字体生成白色 RGBA，缺字暂用该字体的缺字字形。
    pub fn pixels(code: u32, buffer: []u8) dynamic.Char {
        const glyph = FT_Get_Char_Index(face, code);
        // FT_LOAD_RENDER 在加载时直接生成位图。
        if (FT_Load_Glyph(face, glyph, 1 << 2) != 0)
            @panic("font glyph unavailable");

        const slot = face.*.glyph.*;
        const bitmap = slot.bitmap;
        const char = dynamic.Char{
            .rect = .{
                .min = .{
                    .x = @floatFromInt(slot.bitmap_left),
                    .y = -@as(f32, @floatFromInt(slot.bitmap_top)),
                },
                .size = .xy(@floatFromInt(bitmap.width), @floatFromInt(bitmap.rows)),
            },
            .advance = @as(f32, @floatFromInt(slot.advance.x)) / 64,
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

pub const FcConfig = opaque {};
pub const FcPattern = opaque {};
pub const FcResult = c_uint;

pub extern fn FcInitLoadConfigAndFonts() ?*FcConfig;
pub extern fn FcConfigDestroy(*FcConfig) void;
pub extern fn FcPatternCreate() ?*FcPattern;
pub extern fn FcPatternDestroy(*FcPattern) void;
pub extern fn FcPatternAddString(*FcPattern, [*:0]const u8, [*:0]const u8) c_int;
pub extern fn FcPatternAddInteger(*FcPattern, [*:0]const u8, c_int) c_int;
pub extern fn FcConfigSubstitute(*FcConfig, *FcPattern, c_uint) c_int;
pub extern fn FcDefaultSubstitute(*FcPattern) void;
pub extern fn FcFontMatch(*FcConfig, *FcPattern, *FcResult) ?*FcPattern;
pub extern fn FcPatternGetString(
    *const FcPattern,
    [*:0]const u8,
    c_int,
    *[*c]u8,
) FcResult;
pub extern fn FcPatternGetInteger(
    *const FcPattern,
    [*:0]const u8,
    c_int,
    *c_int,
) FcResult;

pub const FT_Library = ?*opaque {};
pub const FT_Face = [*c]Face;

pub extern fn FT_Init_FreeType(*FT_Library) c_int;
pub extern fn FT_Done_FreeType(FT_Library) c_int;
pub extern fn FT_New_Face(FT_Library, [*:0]const u8, c_long, *FT_Face) c_int;
pub extern fn FT_Done_Face(FT_Face) c_int;
pub extern fn FT_Select_Charmap(FT_Face, c_uint) c_int;
pub extern fn FT_Set_Char_Size(FT_Face, c_long, c_long, c_uint, c_uint) c_int;
pub extern fn FT_Get_Char_Index(FT_Face, c_ulong) c_uint;
pub extern fn FT_Load_Glyph(FT_Face, c_uint, i32) c_int;

// FT_FaceRec 只读取 glyph、size；Linux 64/32 位的 glyph 偏移是 152/84。
const Face = extern struct {
    beforeGlyph: [if (@sizeOf(usize) == 8) 152 else 84]u8,
    glyph: [*c]GlyphSlot,
    size: [*c]Size,
};

// FT_SizeRec 只读取基线和行高；度量使用 26.6 定点数。
const Size = extern struct {
    beforeMetrics: [3]?*anyopaque, // 跳过 face 和 generic 的两个指针。
    metrics: extern struct {
        beforeAscent: [3]c_long, // 跳过 ppem、对齐填充和两个缩放值。
        ascender: c_long,
        descender: c_long,
        height: c_long,
    },
};

// FT_GlyphSlotRec 只读取步进、位图和相对基线的位置。
const GlyphSlot = extern struct {
    beforeAdvance: [16]c_long, // 跳过对象指针、通用数据和字形度量。
    advance: extern struct { x: c_long, y: c_long },
    beforeBitmap: c_uint, // 跳过字形格式，位图按指针对齐。
    bitmap: extern struct {
        rows: c_uint,
        width: c_uint,
        pitch: c_int,
        buffer: [*c]u8,
        beforeMode: [2]u8, // 跳过灰阶数量。
        pixel_mode: u8,
        // 跳过调色板模式、对齐填充和指针，保持内嵌位图的完整大小。
        afterMode: [2 * @sizeOf(usize) - 3]u8,
    },
    bitmap_left: c_int,
    bitmap_top: c_int,
};
