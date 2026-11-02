//! macOS 与 iOS 共用系统字体，公共层负责缓存和图集。
const std = @import("std");
const dynamic = @import("../text.zig").dynamic;
const memory = @import("memory.zig");

pub const font = struct {
    var base: *anyopaque = undefined; // 保存所选字体，字号变化时复制。
    var current: ?*anyopaque = null; // 当前像素字号的字体。
    var alpha: []u8 = &.{}; // 复用单通道覆盖率缓冲区。

    // 通用名称映射到系统字体，自定义名称交给 CoreText 解析。
    pub fn open(option: dynamic.Option) void {
        if (std.mem.eql(u8, option.family, "sans-serif")) {
            const language = string("zh-Hans");
            defer CFRelease(language);
            // 2 是系统界面字体，避免依赖系统字体的私有名称。
            base = CTFontCreateUIFontForLanguage(2, option.size, language) orelse
                @panic("system font unavailable");
        } else {
            const name = string(if (std.mem.eql(u8, option.family, "serif"))
                "Times New Roman"
            else if (std.mem.eql(u8, option.family, "monospace"))
                "Menlo"
            else
                option.family);
            defer CFRelease(name);
            base = CTFontCreateWithName(name, option.size, null) orelse
                @panic("font unavailable");
        }
        if (option.weight == .bold) {
            // CoreText 的加粗符号特征占第 1 位。
            const bold = CTFontCreateCopyWithSymbolicTraits(base, //
                0, null, 2, 2) orelse @panic("bold font unavailable");
            CFRelease(base);
            base = bold;
        }
    }

    // 字号变化只替换当前字体，原始字体保留到关闭。
    pub fn resize(size: f32) dynamic.Metrics {
        if (current) |value| CFRelease(value);
        const value = CTFontCreateCopyWithAttributes(base, //
            size, null, null) orelse @panic("font size unavailable");
        current = value;
        const ascent = CTFontGetAscent(value);
        const descent = CTFontGetDescent(value);
        return .{
            .ascent = @floatCast(ascent),
            .descent = @floatCast(descent),
            .height = @floatCast(@max(size, //
                ascent + descent + CTFontGetLeading(value))),
        };
    }

    // 释放 CoreFoundation 对象及复用的像素内存。
    pub fn close() void {
        if (current) |value| CFRelease(value);
        current = null;
        CFRelease(base);
        memory.allocator.free(alpha);
        alpha = &.{};
    }

    // 单码位使用 CTLine，交给系统处理代理对和字体回退。
    pub fn pixels(code: u32, buffer: []u8) dynamic.Char {
        var utf8: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(@intCast(code), &utf8) //
            catch @panic("invalid font code point");
        const text = string(utf8[0..count]);
        defer CFRelease(text);
        // 字典只在创建富文本期间借用键和值，不需要持有回调。
        const keys = [_]*const anyopaque{kCTFontAttributeName};
        const values = [_]*const anyopaque{current.?};
        const attrs = CFDictionaryCreate(null, &keys, //
            &values, 1, null, null) orelse memory.oom();
        defer CFRelease(attrs);
        const styled = CFAttributedStringCreate(null, text, attrs) orelse memory.oom();
        defer CFRelease(styled);
        const line = CTLineCreateWithAttributedString(styled) orelse memory.oom();
        defer CFRelease(line);
        // 使用系统的字形图像边界，也覆盖没有轮廓路径的字形。
        var bounds = CTLineGetImageBounds(line, null);
        // 空格等无可见像素的字形可能返回 CGRectNull，仍保留前进距离。
        if (!std.math.isFinite(bounds.origin.x) or
            !std.math.isFinite(bounds.origin.y))
            bounds = .{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = 0, .height = 0 },
            };
        const left = @floor(bounds.origin.x);
        const bottom = @floor(bounds.origin.y);
        const top = @ceil(bounds.origin.y + bounds.size.height);
        const width: usize = @intFromFloat(
            @ceil(bounds.origin.x + bounds.size.width) - left,
        );
        const height: usize = @intFromFloat(top - bottom);
        const char = dynamic.Char{
            .rect = .{
                .min = .xy(@floatCast(left), @floatCast(-top)),
                .size = .xy(@floatFromInt(width), @floatFromInt(height)),
            },
            .advance = @floatCast(CTLineGetTypographicBounds(line, //
                null, null, null)),
        };
        if (width == 0 or height == 0) return char;
        const stride = width + 2;
        const len = stride * (height + 2);
        if (buffer.len < len * 4) return char;
        if (alpha.len < len) alpha = memory.allocator.realloc(alpha, len);
        @memset(alpha[0..len], 0);
        // 7 是仅含 Alpha 的位图，不涉及预乘 RGB 或通道顺序。
        const context = CGBitmapContextCreate(alpha.ptr, //
            stride, height + 2, 8, stride, null, 7) orelse
            @panic("font bitmap unavailable");
        defer CGContextRelease(context);
        CGContextSetShouldAntialias(context, true);
        CGContextSetShouldSmoothFonts(context, false);
        CGContextSetTextPosition(context, 1 - left, 1 - bottom);
        CTLineDraw(line, context);
        @memset(buffer[0 .. len * 4], 0);
        // Quartz 的位图首行对应顶部，基线定位仍使用向上的坐标。
        for (1..height + 1) |y| {
            for (1..width + 1) |x| {
                const offset = (y * stride + x) * 4;
                @memset(buffer[offset..][0..3], 255);
                buffer[offset + 3] = alpha[y * stride + x];
            }
        }
        return char;
    }
};

// UTF-8 编码编号为 kCFStringEncodingUTF8，CoreFoundation 复制输入字节。
fn string(text: []const u8) *anyopaque {
    return CFStringCreateWithBytes(null, text.ptr, //
        @intCast(text.len), 0x08000100, false) orelse memory.oom();
}

// Apple 64 位平台的 CGFloat 是 double，CFIndex 是有符号指针宽度。
const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { width: f64, height: f64 };
const Rect = extern struct { origin: Point, size: Size };
extern fn CFRelease(*const anyopaque) void;
extern fn CFStringCreateWithBytes(
    ?*anyopaque,
    [*]const u8,
    isize,
    u32,
    bool,
) ?*anyopaque;
extern fn CFDictionaryCreate(
    ?*anyopaque,
    [*]const *const anyopaque,
    [*]const *const anyopaque,
    isize,
    ?*const anyopaque,
    ?*const anyopaque,
) ?*anyopaque;
extern fn CFAttributedStringCreate(
    ?*anyopaque,
    *const anyopaque,
    *const anyopaque,
) ?*anyopaque;
extern var kCTFontAttributeName: *const anyopaque;
extern fn CTFontCreateUIFontForLanguage(u32, f64, *const anyopaque) ?*anyopaque;
extern fn CTFontCreateWithName(*const anyopaque, f64, ?*const anyopaque) ?*anyopaque;
extern fn CTFontCreateCopyWithSymbolicTraits(
    *const anyopaque,
    f64,
    ?*const anyopaque,
    u32,
    u32,
) ?*anyopaque;
extern fn CTFontCreateCopyWithAttributes(
    *const anyopaque,
    f64,
    ?*const anyopaque,
    ?*const anyopaque,
) ?*anyopaque;
extern fn CTFontGetAscent(*const anyopaque) f64;
extern fn CTFontGetDescent(*const anyopaque) f64;
extern fn CTFontGetLeading(*const anyopaque) f64;
extern fn CTLineCreateWithAttributedString(*const anyopaque) ?*anyopaque;
extern fn CTLineGetImageBounds(*const anyopaque, ?*anyopaque) Rect;
extern fn CTLineGetTypographicBounds(
    *const anyopaque,
    ?*f64,
    ?*f64,
    ?*f64,
) f64;
extern fn CTLineDraw(*const anyopaque, *anyopaque) void;
extern fn CGBitmapContextCreate(
    [*]u8,
    usize,
    usize,
    usize,
    usize,
    ?*anyopaque,
    u32,
) ?*anyopaque;
extern fn CGContextRelease(*anyopaque) void;
extern fn CGContextSetShouldAntialias(*anyopaque, bool) void;
extern fn CGContextSetShouldSmoothFonts(*anyopaque, bool) void;
extern fn CGContextSetTextPosition(*anyopaque, f64, f64) void;
