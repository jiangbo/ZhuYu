//! macOS 与 iOS 共用系统字体，公共层负责缓存和图集。
const std = @import("std");

const zhu = @import("../zhu.zig");
const system = @import("../text.zig").system;

const Init = std.process.Init;

// 当前平台的用户数据目录，路径写入调用方缓冲区。
pub fn dataPath(info: Init, name: []const u8, buf: []u8) []const u8 {
    const home = info.environ_map.get("HOME") orelse @panic("HOME not set");
    if (@import("builtin").os.tag == .ios)
        return zhu.format(buf, "{s}/Library/Application Support", .{home});
    return zhu.format(buf, "{s}/Library/Application Support/{s}", .{ home, name });
}

pub fn setup(_: std.mem.Allocator) void {}

pub const font = struct {
    var base: *anyopaque = undefined; // 保存所选字体，字号变化时复制。
    var current: ?*anyopaque = null; // 当前像素字号的字体。
    var colorSpace: ?*anyopaque = null; // 复用设备 RGB 色彩空间。

    // 通用名称映射到系统字体，自定义名称交给 CoreText 解析。
    // 返回完整名称的字节数，缓冲不足时返回零。
    pub fn open(option: system.Option, nameBuffer: []u8) usize {
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
        if (colorSpace == null) {
            colorSpace = CGColorSpaceCreateDeviceRGB() orelse
                @panic("coregraphics: failed to create rgb color space");
        }
        // 从选中的 CoreText 字体读取名称，不使用请求名称。
        const name = CTFontCopyFamilyName(base);
        defer CFRelease(name);
        if (!CFStringGetCString(
            name,
            nameBuffer.ptr,
            @intCast(nameBuffer.len),
            0x08000100,
        )) return 0;
        return std.mem.sliceTo(nameBuffer, 0).len;
    }

    // 字号变化只替换当前字体，原始字体保留到关闭。
    pub fn resize(size: f32) system.Metrics {
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

    // 释放 CoreFoundation 字体对象及色彩空间。
    pub fn close() void {
        if (current) |value| CFRelease(value);
        current = null;
        if (colorSpace) |value| CGColorSpaceRelease(value);
        colorSpace = null;
        CFRelease(base);
    }

    // 单码位使用 CTLine，交给系统处理代理对和字体回退。
    pub fn pixels(code: u32, buffer: *system.Buffer) system.Char {
        var utf8: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(@intCast(code), &utf8) //
            catch @panic("invalid font code point");
        const text = string(utf8[0..count]);
        defer CFRelease(text);
        // 字典只在创建富文本期间借用键和值，不需要持有回调。
        const keys = [_]*const anyopaque{
            kCTFontAttributeName,
            kCTForegroundColorFromContextAttributeName,
        };
        const values = [_]*const anyopaque{ current.?, kCFBooleanTrue };
        const attrs = CFDictionaryCreate(null, &keys, //
            &values, keys.len, null, null) orelse
            @panic("corefoundation: failed to create font attributes");
        defer CFRelease(attrs);
        const styled = CFAttributedStringCreate(null, text, attrs) orelse
            @panic("corefoundation: failed to create styled font text");
        defer CFRelease(styled);
        const line = CTLineCreateWithAttributedString(styled) orelse
            @panic("coretext: failed to create font line");
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
        const char = system.Char{
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
        const data = buffer.resize(len * 4);
        @memset(data[0 .. len * 4], 0);
        // 1 是 kCGImageAlphaPremultipliedLast，直接生成预乘 RGBA 数据。
        const context = CGBitmapContextCreate(data.ptr, //
            stride, height + 2, 8, stride * 4, colorSpace, 1) orelse
            @panic("font bitmap unavailable");
        defer CGContextRelease(context);
        CGContextSetShouldAntialias(context, true);
        CGContextSetShouldSmoothFonts(context, false);
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextSetTextPosition(context, 1 - left, 1 - bottom);
        CTLineDraw(line, context);
        return char;
    }
};

// UTF-8 编码编号为 kCFStringEncodingUTF8，CoreFoundation 复制输入字节。
fn string(text: []const u8) *anyopaque {
    return CFStringCreateWithBytes(null, text.ptr, //
        @intCast(text.len), 0x08000100, false) orelse
        @panic("corefoundation: failed to create UTF-8 string");
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
extern var kCFBooleanTrue: *const anyopaque;
extern var kCTFontAttributeName: *const anyopaque;
extern var kCTForegroundColorFromContextAttributeName: *const anyopaque;
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
extern fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern fn CGColorSpaceRelease(*anyopaque) void;
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
extern fn CGContextSetRGBFillColor(*anyopaque, f64, f64, f64, f64) void;
extern fn CGContextSetTextPosition(*anyopaque, f64, f64) void;

extern fn CTFontCopyFamilyName(*const anyopaque) *anyopaque;
extern fn CFStringGetCString(*const anyopaque, [*]u8, isize, u32) bool;
