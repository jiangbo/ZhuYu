//! Windows 平台接口，字体实现放在内部模块中。
const std = @import("std");

const dynamic = @import("../text.zig").dynamic;
const DateTime = @import("platform.zig").DateTime;
const assert = std.debug.assert;

pub fn setup(_: std.mem.Allocator) void {}

pub fn localTime(seconds: i64) DateTime {
    // FILETIME 从 1601 年开始，单位为 100 纳秒。
    const fileSeconds = @as(i128, seconds) + 11644473600;
    const ticks: u64 = @intCast(fileSeconds * 10000000);
    const file: FileTime = .{
        .dwLowDateTime = @truncate(ticks),
        .dwHighDateTime = @intCast(ticks >> 32),
    };
    var utc: SystemTime = undefined;
    assert(FileTimeToSystemTime(&file, &utc) != 0);
    var result: SystemTime = undefined;
    // 空时区指针使用系统当前时区，并按目标日期应用动态夏令时规则。
    assert(SystemTimeToTzSpecificLocalTimeEx(null, &utc, &result) != 0);
    var local: FileTime = undefined;
    assert(SystemTimeToFileTime(&result, &local) != 0);
    const localTicks = (@as(i128, local.dwHighDateTime) << 32) |
        local.dwLowDateTime;
    return .{
        .year = result.year,
        .month = result.month,
        .day = result.day,
        .hour = result.hour,
        .minute = result.minute,
        .second = result.second,
        .utcOffset = @intCast(@divTrunc(localTicks - ticks, 10000000)),
    };
}

// COM 接口的首字段都是虚表指针，前三个方法共用 IUnknown ABI。
fn releaseObject(object: *anyopaque) void {
    const table: *const *const Unknown = @ptrCast(@alignCast(object));
    _ = table.*.Release(object);
}

// Windows 系统字体的单例状态，位图容量在内部按需扩展。
pub const font = struct {
    var factory: *IDWriteFactory = undefined; // DirectWrite 工厂。
    var fonts: *IDWriteFontCollection = undefined; // 系统字体集合。
    var bitmap: *IDWriteBitmapRenderTarget1 = undefined; // 灰度绘制目标。
    var params: *IDWriteRenderingParams = undefined; // 灰度渲染参数。
    var face: *IDWriteFontFace = undefined; // 当前选定的字体面。
    var bitmapWidth: u32 = undefined; // 位图当前容量宽度。
    var bitmapHeight: u32 = undefined; // 位图当前容量高度。
    var metrics: DWRITE_FONT_METRICS = undefined; // 当前字体的设计度量。

    // 测量结果只记录后续绘制需要的数据，不持有临时分析对象。
    const Glyph = struct {
        index: u16,
        size: f32,
        rect: RECT,
        advance: f32,
    };

    var fontSize: f32 = undefined; // 当前像素字号。

    // 按名称和字重选择字体，并创建可复用的灰度位图目标。
    // 返回完整名称的字节数，缓冲不足时返回零。
    pub fn open(option: dynamic.Option, nameBuffer: []u8) usize {
        init();

        // 通用名称映射到 Windows 的中文字体，最后才选择西文字体。
        if (std.mem.eql(u8, option.family, "sans-serif")) {
            for ([_][]const u8{
                "Microsoft YaHei UI",
                "Microsoft YaHei",
                "SimHei",
                "Noto Sans CJK SC",
                "Segoe UI",
                "Arial",
            }) |name| {
                if (findFont(name, option.weight == .bold, nameBuffer)) |len|
                    return len;
            }
            @panic("default font unavailable");
        }
        return findFont(option.family, option.weight == .bold, nameBuffer) orelse
            std.debug.panic("font unavailable: {s}", .{option.family});
    }

    // 设计单位按当前像素字号换算，基线上下距离均返回正值。
    pub fn resize(size: f32) dynamic.Metrics {
        fontSize = size;
        const fontMetrics = metrics;
        const factor = size / @as(f32, @floatFromInt(fontMetrics.designUnitsPerEm));
        const ascent = @as(f32, @floatFromInt(fontMetrics.ascent)) * factor;
        const descent = @as(f32, @floatFromInt(fontMetrics.descent)) * factor;
        const gap = @as(f32, @floatFromInt(fontMetrics.lineGap)) * factor;
        return .{
            .ascent = ascent,
            .descent = descent,
            .height = @max(size, ascent + descent + gap),
        };
    }

    // 先测量字形，公共缓冲容量足够时才生成带透明边框的白色 RGBA。
    pub fn pixels(code: u32, buffer: []u8) dynamic.Char {
        const glyph = measureGlyph(code, fontSize);
        const rect = glyph.rect;
        const width: u32 = @intCast(rect.right - rect.left);
        const height: u32 = @intCast(rect.bottom - rect.top);
        const char = dynamic.Char{
            .rect = .{
                .min = .xy(@floatFromInt(rect.left), @floatFromInt(rect.top)),
                .size = .xy(@floatFromInt(width), @floatFromInt(height)),
            },
            .advance = glyph.advance,
        };
        if (width == 0 or height == 0) return char;
        const stride = (@as(usize, width) + 2) * 4;
        const len = stride * (height + 2);
        if (buffer.len < len) return char;

        drawGlyph(glyph, buffer);
        return char;
    }

    // 创建灰度绘制环境，统一处理 COM 接口版本、渲染参数和引用。
    fn init() void {
        assert(DWriteCreateFactory(0, &.{
            .Data1 = 0xb859ee5a,
            .Data2 = 0xd838,
            .Data3 = 0x4b5b,
            .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
        }, @ptrCast(&factory)) >= 0);

        assert(factory.lpVtbl.GetSystemFontCollection(factory, &fonts, 0) >= 0);

        var gdi: *IDWriteGdiInterop = undefined;
        assert(factory.lpVtbl.GetGdiInterop(factory, &gdi) >= 0);
        defer releaseObject(gdi);
        var base: *IDWriteBitmapRenderTarget = undefined;
        assert(gdi.lpVtbl.CreateBitmapRenderTarget(gdi, null, 1, 1, &base) >= 0);
        defer releaseObject(base);
        assert(base.lpVtbl.QueryInterface(base, &.{
            .Data1 = 0x791e8298,
            .Data2 = 0x3ef3,
            .Data3 = 0x4230,
            .Data4 = .{ 0x98, 0x80, 0xc9, 0xbd, 0xec, 0xc4, 0x20, 0x64 },
        }, @ptrCast(&bitmap)) >= 0);
        assert(bitmap.lpVtbl.SetTextAntialiasMode(bitmap, 1) >= 0);
        // 使用线性灰度覆盖率，避免再叠加系统 DPI 放大。
        assert(bitmap.lpVtbl.SetPixelsPerDip(bitmap, 1) >= 0);
        assert(factory.lpVtbl.CreateCustomRenderingParams(factory, 1, //
            0, 0, 0, 5, &params) >= 0);
        bitmapWidth = 1;
        bitmapHeight = 1;
    }

    // 释放选定字体和共用的绘制环境。
    pub fn close() void {
        releaseObject(face);
        releaseObject(bitmap);
        releaseObject(params);
        releaseObject(fonts);
        releaseObject(factory);
    }

    // 完成字体面创建并写入名称；未找到字体时返回 null。
    fn findFont(name: []const u8, bold: bool, nameBuffer: []u8) ?usize {
        // 栈上转换字体名，先检查编码和长度，为结尾零预留一个单元。
        var wide: [1024]u16 = undefined;
        if (!std.unicode.utf8ValidateSlice(name))
            @panic("font name is not valid UTF-8");
        const len = std.unicode.calcUtf16LeLen(name) catch unreachable;
        if (len >= wide.len)
            @panic("font name exceeds 1023 UTF-16 units");
        _ = std.unicode.utf8ToUtf16Le(wide[0..len], name) catch unreachable;
        wide[len] = 0;
        var index: u32 = undefined;
        var exists: i32 = 0;
        assert(fonts.lpVtbl.FindFamilyName(fonts, wide[0..len :0].ptr, //
            &index, &exists) >= 0);
        if (exists == 0) return null;

        var family: *IDWriteFontFamily = undefined;
        assert(fonts.lpVtbl.GetFontFamily(fonts, index, &family) >= 0);
        defer releaseObject(family);
        var matched: *IDWriteFont = undefined;
        assert(family.lpVtbl.GetFirstMatchingFont(family, //
            if (bold) 700 else 400, 5, 0, &matched) >= 0);
        defer releaseObject(matched);
        assert(matched.lpVtbl.CreateFontFace(matched, &face) >= 0);
        face.lpVtbl.GetMetrics(face, &metrics);
        // 从匹配到的字体族读取正式名称，不保留请求别名。
        var names: *IDWriteLocalizedStrings = undefined;
        assert(family.lpVtbl.GetFamilyNames(family, &names) >= 0);
        defer releaseObject(names);
        var length: u32 = undefined;
        assert(names.lpVtbl.GetStringLength(names, 0, &length) >= 0);
        // 复用查找时的 UTF-16 栈缓冲，接口要求能装下名称及结尾零。
        if (length >= wide.len) return 0;
        assert(names.lpVtbl.GetString(names, 0, &wide, wide.len) >= 0);
        const selected = wide[0..length];
        if (std.unicode.calcWtf8Len(selected) > nameBuffer.len) return 0;
        return std.unicode.utf16LeToUtf8(nameBuffer, selected) catch
            @panic("invalid font name");
    }

    // 一次查询字形编号、步进和像素范围，临时分析对象在内部释放。
    fn measureGlyph(code: u32, size: f32) Glyph {
        var index: u16 = undefined;
        assert(face.lpVtbl.GetGlyphIndices(face, @ptrCast(&code), //
            1, @ptrCast(&index)) >= 0);
        var glyphMetrics: DWRITE_GLYPH_METRICS = undefined;
        assert(face.lpVtbl.GetDesignGlyphMetrics(face, //
            @ptrCast(&index), 1, &glyphMetrics, 0) >= 0);
        var glyph = Glyph{
            .index = index,
            .size = size,
            .rect = undefined,
            .advance = @as(f32, @floatFromInt(glyphMetrics.advanceWidth)) * size /
                @as(f32, @floatFromInt(metrics.designUnitsPerEm)),
        };
        const run = glyphRun(&glyph);
        var analysis: *IDWriteGlyphRunAnalysis = undefined;
        assert(factory.lpVtbl.CreateGlyphRunAnalysis(factory, &run, //
            1, null, 5, 0, 0, 0, &analysis) >= 0);
        defer releaseObject(analysis);
        assert(analysis.lpVtbl.GetAlphaTextureBounds(analysis, 1, &glyph.rect) >= 0);
        return glyph;
    }

    // 输出带一像素透明边框的白色 RGBA，隐藏位图扩容和灰度读取细节。
    fn drawGlyph(glyph: Glyph, buffer: []u8) void {
        const width: u32 = @intCast(glyph.rect.right - glyph.rect.left);
        const height: u32 = @intCast(glyph.rect.bottom - glyph.rect.top);
        if (width == 0 or height == 0) return;
        const stride = (@as(usize, width) + 2) * 4;
        const len = stride * (height + 2);
        assert(buffer.len >= len);

        if (width > bitmapWidth or height > bitmapHeight) {
            const nextWidth = @max(width, bitmapWidth);
            const nextHeight = @max(height, bitmapHeight);
            assert(bitmap.lpVtbl.Resize(bitmap, nextWidth, nextHeight) >= 0);
            bitmapWidth, bitmapHeight = .{ nextWidth, nextHeight };
        }
        const dc = bitmap.lpVtbl.GetMemoryDC(bitmap);
        var dib: DIBSECTION = undefined;
        if (GetObjectW(GetCurrentObject(dc, 7), @sizeOf(DIBSECTION), &dib) !=
            @sizeOf(DIBSECTION)) @panic("GetObjectW: invalid font bitmap");
        const pointer = dib.dsBm.bmBits orelse @panic("font bitmap has no pixels");
        if (dib.dsBm.bmWidthBytes <= 0)
            @panic("font bitmap has invalid row size");
        const pitch: usize = @intCast(dib.dsBm.bmWidthBytes);
        const data: [*]u8 = @ptrCast(pointer);
        // 黑底白字的灰度就是覆盖率，不依赖位图的 Alpha 通道。
        @memset(data[0 .. pitch * bitmapHeight], 0);
        const run = glyphRun(&glyph);
        assert(bitmap.lpVtbl.DrawGlyphRun(
            bitmap,
            -@as(f32, @floatFromInt(glyph.rect.left)),
            -@as(f32, @floatFromInt(glyph.rect.top)),
            0,
            &run,
            params,
            0xffffff,
            null,
        ) >= 0);
        @memset(buffer[0..len], 0);
        for (0..height) |y| {
            // DirectWrite 位图自顶向下，GetObject 的高度符号不表示方向。
            for (0..width) |x| {
                const offset = (y + 1) * stride + (x + 1) * 4;
                @memset(buffer[offset..][0..3], 255);
                buffer[offset + 3] = data[y * pitch + x * 4];
            }
        }
    }

    // 测量与绘制共用字形描述，指针只在当前系统调用期间借用。
    fn glyphRun(glyph: *const Glyph) DWRITE_GLYPH_RUN {
        return .{
            .fontFace = face,
            .fontEmSize = glyph.size,
            .glyphCount = 1,
            .glyphIndices = @ptrCast(&glyph.index),
            .glyphAdvances = @ptrCast(&glyph.advance),
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };
    }
};

// 按 Windows ABI 声明，x86 使用 stdcall，x64 和 ARM64 使用各自的系统调用约定。
pub extern "imm32" fn ImmDisableIME(i32) callconv(.winapi) std.os.windows.BOOL;

const FileTime = std.os.windows.FILETIME;
const SystemTime = extern struct {
    year: u16,
    month: u16,
    weekDay: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    millisecond: u16,
};

extern "kernel32" fn FileTimeToSystemTime(
    *const FileTime,
    *SystemTime,
) callconv(.winapi) c_int;
extern "kernel32" fn SystemTimeToFileTime(
    *const SystemTime,
    *FileTime,
) callconv(.winapi) c_int;
extern "kernel32" fn SystemTimeToTzSpecificLocalTimeEx(
    ?*const anyopaque,
    *const SystemTime,
    *SystemTime,
) callconv(.winapi) c_int;

// DirectWrite 与 GDI 的原始 ABI 声明。
const Guid = std.os.windows.GUID;
const HRESULT = i32;
const BOOL = i32;

extern "dwrite" fn DWriteCreateFactory(
    u32,
    *const Guid,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "gdi32" fn GetCurrentObject(
    ?*anyopaque,
    u32,
) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn GetObjectW(
    ?*anyopaque,
    i32,
    *anyopaque,
) callconv(.winapi) i32;

// 公共 IUnknown 前缀，所有接口的前三个方法使用相同 ABI。
const Unknown = extern struct {
    QueryInterface: *const fn (
        *anyopaque,
        *const Guid,
        *?*anyopaque,
    ) callconv(.winapi) HRESULT,
    addRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
const IDWriteBitmapRenderTarget = extern struct { lpVtbl: *const Unknown };
const IDWriteRenderingParams = extern struct { lpVtbl: *const Unknown };

const IDWriteFactory = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        GetSystemFontCollection: *const fn (
            *IDWriteFactory,
            **IDWriteFontCollection,
            BOOL,
        ) callconv(.winapi) HRESULT,
        beforeParams: [8]*const anyopaque,
        CreateCustomRenderingParams: *const fn (
            *IDWriteFactory,
            f32,
            f32,
            f32,
            u32,
            u32,
            **IDWriteRenderingParams,
        ) callconv(.winapi) HRESULT,
        beforeInterop: [4]*const anyopaque,
        GetGdiInterop: *const fn (
            *IDWriteFactory,
            **IDWriteGdiInterop,
        ) callconv(.winapi) HRESULT,
        beforeAnalysis: [5]*const anyopaque,
        CreateGlyphRunAnalysis: *const fn (
            *IDWriteFactory,
            *const DWRITE_GLYPH_RUN,
            f32,
            ?*const anyopaque,
            u32,
            u32,
            f32,
            f32,
            **IDWriteGlyphRunAnalysis,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteGlyphRunAnalysis = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        GetAlphaTextureBounds: *const fn (
            *IDWriteGlyphRunAnalysis,
            u32,
            *RECT,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteFontCollection = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        count: *const anyopaque,
        GetFontFamily: *const fn (
            *IDWriteFontCollection,
            u32,
            **IDWriteFontFamily,
        ) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (
            *IDWriteFontCollection,
            [*:0]const u16,
            *u32,
            *BOOL,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteFontFamily = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        beforeNames: [3]*const anyopaque,
        GetFamilyNames: *const fn (
            *IDWriteFontFamily,
            **IDWriteLocalizedStrings,
        ) callconv(.winapi) HRESULT,
        GetFirstMatchingFont: *const fn (
            *IDWriteFontFamily,
            u32,
            u32,
            u32,
            **IDWriteFont,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteFont = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        beforeFace: [10]*const anyopaque,
        CreateFontFace: *const fn (
            *IDWriteFont,
            **IDWriteFontFace,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteFontFace = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        beforeMetrics: [5]*const anyopaque,
        GetMetrics: *const fn (
            *IDWriteFontFace,
            *DWRITE_FONT_METRICS,
        ) callconv(.winapi) void,
        glyphCount: *const anyopaque,
        GetDesignGlyphMetrics: *const fn (
            *IDWriteFontFace,
            [*]const u16,
            u32,
            *DWRITE_GLYPH_METRICS,
            BOOL,
        ) callconv(.winapi) HRESULT,
        GetGlyphIndices: *const fn (
            *IDWriteFontFace,
            [*]const u32,
            u32,
            [*]u16,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteGdiInterop = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        beforeBitmap: [4]*const anyopaque,
        CreateBitmapRenderTarget: *const fn (
            *IDWriteGdiInterop,
            ?*anyopaque,
            u32,
            u32,
            **IDWriteBitmapRenderTarget,
        ) callconv(.winapi) HRESULT,
    },
};
const IDWriteBitmapRenderTarget1 = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        DrawGlyphRun: *const fn (
            *IDWriteBitmapRenderTarget1,
            f32,
            f32,
            u32,
            *const DWRITE_GLYPH_RUN,
            *IDWriteRenderingParams,
            u32,
            ?*RECT,
        ) callconv(.winapi) HRESULT,
        GetMemoryDC: *const fn (
            *IDWriteBitmapRenderTarget1,
        ) callconv(.winapi) ?*anyopaque,
        getPixelsPerDip: *const anyopaque,
        SetPixelsPerDip: *const fn (
            *IDWriteBitmapRenderTarget1,
            f32,
        ) callconv(.winapi) HRESULT,
        beforeResize: [3]*const anyopaque,
        Resize: *const fn (
            *IDWriteBitmapRenderTarget1,
            u32,
            u32,
        ) callconv(.winapi) HRESULT,
        getAntialias: *const anyopaque,
        SetTextAntialiasMode: *const fn (
            *IDWriteBitmapRenderTarget1,
            u32,
        ) callconv(.winapi) HRESULT,
    },
};

const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};
const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};
const DWRITE_GLYPH_RUN = extern struct {
    fontFace: *IDWriteFontFace,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: [*]const f32,
    glyphOffsets: ?*const anyopaque,
    isSideways: BOOL,
    bidiLevel: u32,
};
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const DIBSECTION = extern struct {
    dsBm: extern struct {
        bmType: i32,
        bmWidth: i32,
        bmHeight: i32,
        bmWidthBytes: i32,
        bmPlanes: u16,
        bmBitsPixel: u16,
        bmBits: ?*anyopaque,
    },
    dsBmih: extern struct {
        biSize: u32,
        biWidth: i32,
        biHeight: i32,
        biPlanes: u16,
        biBitCount: u16,
        biCompression: u32,
        biSizeImage: u32,
        biXPelsPerMeter: i32,
        biYPelsPerMeter: i32,
        biClrUsed: u32,
        biClrImportant: u32,
    },
    dsBitfields: [3]u32,
    dshSection: ?*anyopaque,
    dsOffset: u32,
};

// DirectWrite 本地化名称列表，索引零提供字体自身记录的名称。
const IDWriteLocalizedStrings = extern struct {
    lpVtbl: *const extern struct {
        unknown: Unknown,
        beforeLength: [4]*const anyopaque,
        GetStringLength: *const fn (
            *IDWriteLocalizedStrings,
            u32,
            *u32,
        ) callconv(.winapi) HRESULT,
        GetString: *const fn (
            *IDWriteLocalizedStrings,
            u32,
            [*]u16,
            u32,
        ) callconv(.winapi) HRESULT,
    },
};
