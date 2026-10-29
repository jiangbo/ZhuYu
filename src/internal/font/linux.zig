//! Linux 字体库的最小 C ABI 声明，构建和运行都不依赖 C 头文件。
//! FreeType 对象由库分配；这里只声明读取字段所需的结构体前缀。

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
pub extern fn FT_Set_Pixel_Sizes(FT_Face, c_uint, c_uint) c_int;
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
