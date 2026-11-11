//! 浏览器宿主接口，JavaScript 源码直接嵌入 Emscripten 的链接段。
const std = @import("std");

const zhu = @import("../zhu.zig");
const DateTime = @import("platform.zig").DateTime;
const dynamic = @import("../text.zig").dynamic;

const Allocator = std.mem.Allocator;

pub fn setup(_: std.mem.Allocator) void {}

// 秒数以 double 传递，避免 Wasm i64 与 JavaScript BigInt 的转换。
extern "env" fn zhu_local_time(f64, *DateTime) void;

pub fn localTime(seconds: i64) DateTime {
    var result: DateTime = undefined;
    zhu_local_time(@floatFromInt(seconds), &result);
    return result;
}

// 浏览器系统字体接口，画布状态由嵌入的 JavaScript 持有。
pub const font = struct {
    // 打开浏览器字体，宿主创建失败时直接终止。
    // 浏览器无法查询实际名称，返回零，由公共层使用 family。
    pub fn open(option: dynamic.Option, nameBuffer: []u8) usize {
        _ = nameBuffer;
        const weight: u32 = switch (option.weight) {
            .normal => 400,
            .bold => 700,
        };
        if (zhu_font_open(option.family, weight) != 0)
            @panic("font unavailable");
        return 0;
    }

    // 释放浏览器保存的字体和画布引用。
    pub fn close() void {
        zhu_font_close();
    }

    // 设置像素字号并读取字体度量，后续像素生成沿用此字号。
    pub fn resize(size: f32) dynamic.Metrics {
        var result: dynamic.Metrics = undefined;
        zhu_font_metrics(size, &result);
        return result;
    }

    // 容量不足时只返回字形信息，不写像素，等待扩容后再次调用。
    pub fn pixels(code: u32, buffer: []u8) dynamic.Char {
        var char: dynamic.Char = undefined;
        _ = zhu_font_pixels(code, &char, buffer.ptr, @intCast(buffer.len));
        return char;
    }
};

// 浏览器用户数据存储，内部为文件名添加应用名称前缀。
pub const storage = struct {
    var nameBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dataName: []const u8 = "";

    pub fn setup(name: []const u8) []const u8 {
        dataName = zhu.format(&nameBuffer, "{s}", .{name});
        return dataName;
    }

    pub fn exists(path: [:0]const u8) bool {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return existsKey(key(&buf, path));
    }

    pub fn readBuffer(path: [:0]const u8, buf: []u8) ![:0]u8 {
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const result = try load(key(&keyBuffer, path), buf[0 .. buf.len - 1]);
        return switch (result) {
            .loaded => |content| blk: {
                buf[content.len] = 0;
                break :blk buf[0..content.len :0];
            },
            .tooSmall => error.BufferTooSmall,
        };
    }

    pub fn readAll(gpa: Allocator, path: [:0]const u8) ![:0]u8 {
        var buf: [4096]u8 = undefined;
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pathKey = key(&keyBuffer, path);
        return switch (try load(pathKey, &buf)) {
            .loaded => |content| try gpa.dupeSentinel(u8, content, 0),
            .tooSmall => |len| blk: {
                const large = try gpa.allocSentinel(u8, len, 0);
                errdefer gpa.free(large);
                switch (try load(pathKey, large)) {
                    .loaded => break :blk large,
                    .tooSmall => return error.BufferTooSmall,
                }
            },
        };
    }

    pub fn writeAll(path: [:0]const u8, content: []const u8) !void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try save(key(&buf, path), content);
    }

    fn key(buf: []u8, path: [:0]const u8) [:0]u8 {
        if (dataName.len == 0) @panic("set a storage name in zhu.setup");
        return zhu.formatZ(buf, "{s}/{s}", .{ dataName, path });
    }

    const Load = union(enum) { loaded: []u8, tooSmall: usize };

    // 浏览器存档函数由 web.zig 的 JavaScript 描述静态接入。
    extern fn zhu_file_exists(path: [*:0]const u8) c_int;
    extern fn zhu_file_load(path: [*:0]const u8, out: [*]u8, len: c_int) c_int;
    extern fn zhu_file_save(path: [*:0]const u8, data: [*]const u8, len: c_int) c_int;

    /// 检查浏览器中是否存在存档。
    fn existsKey(path: [:0]const u8) bool {
        return zhu_file_exists(path.ptr) != 0;
    }

    /// 读取浏览器存档，将原始字节写入传入的缓冲区。
    fn load(path: [:0]const u8, buffer: []u8) !Load {
        const len = zhu_file_load(path.ptr, buffer.ptr, @intCast(buffer.len));
        if (len == 0 and !existsKey(path)) return error.FileNotFound;
        if (len < 0) return .{ .tooSmall = @intCast(-len) };
        return .{ .loaded = buffer[0..@intCast(len)] };
    }

    /// 将存档字节编码为 Base64，保存到浏览器。
    fn save(path: [:0]const u8, data: []const u8) !void {
        const err = zhu_file_save(path.ptr, data.ptr, @intCast(data.len));
        if (err != 0) return error.WriteFailed;
    }
};

// 查询主要指针类型，用于推测是否缺少实体键盘。
pub extern "env" fn zhu_coarse_pointer() c_int;

// DateTime 按声明顺序保存七个 i32，偏移秒数采用东区为正的约定。
export var __em_js__zhu_local_time align(1) linksection("em_js") =
    (
        \\(double seconds, int *out)<::>{
        \\    const date = new Date(seconds * 1000);
        \\    const local = new Date(0);
        \\    local.setUTCFullYear(date.getFullYear(), date.getMonth(), date.getDate());
        \\    const hour = date.getHours(), minute = date.getMinutes();
        \\    local.setUTCHours(hour, minute, date.getSeconds(), 0);
        \\    HEAP32[out >> 2] = date.getFullYear();
        \\    HEAP32[(out >> 2) + 1] = date.getMonth() + 1;
        \\    HEAP32[(out >> 2) + 2] = date.getDate();
        \\    HEAP32[(out >> 2) + 3] = hour;
        \\    HEAP32[(out >> 2) + 4] = minute;
        \\    HEAP32[(out >> 2) + 5] = date.getSeconds();
        \\    HEAP32[(out >> 2) + 6] = (local.getTime() - date.getTime()) / 1000;
        \\}
    ).*;

// 打开、关闭浏览器字体，并读取像素度量和字形数据。
pub extern "env" fn zhu_font_open([*:0]const u8, u32) c_int;
pub extern "env" fn zhu_font_close() void;
pub extern "env" fn zhu_font_metrics(f32, *dynamic.Metrics) void;
pub extern "env" fn zhu_font_pixels(u32, *dynamic.Char, [*]u8, u32) c_int;

// 浏览器请求的发起与取消；请求状态和缓冲区由加载器持有。
pub extern fn zhu_fetch_start(lane: c_int, path: [*:0]const u8) void;
pub extern fn zhu_fetch_stop() void;

// 显式保留 JavaScript 读取 Wasm 字符串所需的运行库函数。
export var __em_lib_deps_zhu_storage align(1) linksection("em_lib_deps") =
    "$UTF8ToString".*;

// 创建离屏画布并保存唯一的字体状态。
export var __em_js__zhu_font_open align(1) linksection("em_js") =
    (
        \\(const char *family, unsigned int weight)<::>{
        \\    const canvas = typeof OffscreenCanvas !== "undefined"
        \\        ? new OffscreenCanvas(1, 1) : document.createElement("canvas");
        \\    const context = canvas.getContext("2d", { willReadFrequently: true });
        \\    if (!context) return 1;
        \\    // 字体系统只允许打开一个字体，直接保存供后续调用复用。
        \\    Module.zhu_font = {
        \\        canvas, context, family: UTF8ToString(family), weight,
        \\    };
        \\    return 0;
        \\}
    ).*;

// 释放浏览器保存的字体和离屏画布引用。
export var __em_js__zhu_font_close align(1) linksection("em_js") =
    (
        \\(void)<::>{
        \\    Module.zhu_font = null;
        \\}
    ).*;

// 设置像素字号并读取基线和行高度量。
export var __em_js__zhu_font_metrics align(1) linksection("em_js") =
    (
        \\(float size, float *out)<::>{
        \\    const zhuFont = Module.zhu_font;
        \\    zhuFont.style = zhuFont.weight + " " + size + "px " + zhuFont.family;
        \\    zhuFont.context.font = zhuFont.style;
        \\    const metrics = zhuFont.context.measureText("国Mg");
        \\    const ascent = metrics.fontBoundingBoxAscent
        \\        ?? metrics.actualBoundingBoxAscent;
        \\    const descent = metrics.fontBoundingBoxDescent
        \\        ?? metrics.actualBoundingBoxDescent;
        \\    HEAPF32[out >> 2] = ascent;
        \\    HEAPF32[(out >> 2) + 1] = descent;
        \\    HEAPF32[(out >> 2) + 2] = Math.max(size, ascent + descent);
        \\}
    ).*;

// 先读取字形边界，容量足够时才输出带透明边框的 RGBA。
export var __em_js__zhu_font_pixels align(1) linksection("em_js") =
    (
        \\(unsigned int code, float *info, unsigned char *out, unsigned int len)<::>{
        \\    const zhuFont = Module.zhu_font;
        \\    const context = zhuFont.context;
        \\    const text = String.fromCodePoint(code);
        \\    const metrics = context.measureText(text);
        \\    const left = Math.floor(-metrics.actualBoundingBoxLeft);
        \\    const top = Math.ceil(metrics.actualBoundingBoxAscent);
        \\    const width = Math.ceil(metrics.actualBoundingBoxRight) - left;
        \\    const height = top + Math.ceil(metrics.actualBoundingBoxDescent);
        \\    // Char 的内存顺序为 x、y、width、height、advance，基线上方的 y 为负。
        \\    HEAPF32[info >> 2] = left;
        \\    HEAPF32[(info >> 2) + 1] = -top;
        \\    HEAPF32[(info >> 2) + 2] = width;
        \\    HEAPF32[(info >> 2) + 3] = height;
        \\    HEAPF32[(info >> 2) + 4] = metrics.width;
        \\    if (width === 0 || height === 0) return 0;
        \\    // 包含一像素透明边框，Zig 可以将整块数据直接写入上传缓冲。
        \\    const copyWidth = width + 2;
        \\    const copyHeight = height + 2;
        \\    // 容量不足时不写入像素，等待调用方扩容后再次调用。
        \\    if (copyWidth * copyHeight * 4 > len) return 1;
        \\
        \\    // 修改画布尺寸会重置绘图状态，恢复 metrics 已设置的字体和字号。
        \\    zhuFont.canvas.width = copyWidth;
        \\    zhuFont.canvas.height = copyHeight;
        \\    context.font = zhuFont.style;
        \\    context.textBaseline = "alphabetic";
        \\    context.fillStyle = "white";
        \\    context.fillText(text, 1 - left, 1 + top);
        \\    const data = context.getImageData(0, 0, copyWidth, copyHeight).data;
        \\    HEAPU8.set(data, out);
        \\    return 0;
        \\}
    ).*;

// 通过媒体查询判断主要指针是否为粗略指针。
export var __em_js__zhu_coarse_pointer align(1) linksection("em_js") =
    (
        \\(void)<::>{
        \\    return window.matchMedia('(pointer: coarse)').matches ? 1 : 0;
        \\}
    ).*;

// 每个槽位只保留一个请求，完成后将结果通知 Wasm。
export var __em_js__zhu_fetch_start align(1) linksection("em_js") =
    (
        \\(int lane, const char *path)<::>{
        \\    const jobs = Module.zhu_fetch_jobs ||= [];
        \\    const job = new AbortController();
        \\    jobs[lane] = job;
        \\    fetch("assets/" + UTF8ToString(path), { signal: job.signal })
        \\    .then(async response => {
        \\        if (!response.ok) {
        \\            if (jobs[lane] === job) {
        \\                jobs[lane] = null;
        \\                _zhu_fetch_done(lane, 1);
        \\            }
        \\            return;
        \\        }
        \\        const data = new Uint8Array(await response.arrayBuffer());
        \\        if (jobs[lane] !== job) return;
        \\        jobs[lane] = null;
        \\        const out = _zhu_fetch_alloc(lane, data.length);
        \\        HEAPU8.set(data, out);
        \\        _zhu_fetch_done(lane, 0);
        \\    }).catch(() => {
        \\        if (jobs[lane] !== job) return;
        \\        jobs[lane] = null;
        \\        _zhu_fetch_done(lane, 3);
        \\    });
        \\}
    ).*;

// 中止全部请求，旧 Promise 不再访问已释放的缓冲区。
export var __em_js__zhu_fetch_stop align(1) linksection("em_js") =
    (
        \\(void)<::>{
        \\    const jobs = Module.zhu_fetch_jobs || [];
        \\    for (let lane = 0; lane < jobs.length; lane++) {
        \\        const job = jobs[lane];
        \\        jobs[lane] = null;
        \\        if (job) job.abort();
        \\    }
        \\}
    ).*;

// 检查浏览器中是否存在存档。
export var __em_js__zhu_file_exists align(1) linksection("em_js") =
    (
        \\(const char *name)<::>{
        \\    const path = UTF8ToString(name);
        \\    try {
        \\        return window.localStorage.getItem(path) !== null;
        \\    } catch (err) {
        \\        console.error("check file failed:", path, err);
        \\        return false;
        \\    }
        \\}
    ).*;

// 读取存档字节，缓冲区不足时返回所需长度的负值。
export var __em_js__zhu_file_load align(1) linksection("em_js") =
    (
        \\(const char *name, unsigned char *out, int len)<::>{
        \\    const path = UTF8ToString(name);
        \\    try {
        \\        const base64 = window.localStorage.getItem(path);
        \\        if (!base64) return 0;
        \\        const binary = atob(base64);
        \\        if (binary.length > len) return -binary.length;
        \\        for (let i = 0; i < binary.length; i++) {
        \\            HEAPU8[out + i] = binary.charCodeAt(i);
        \\        }
        \\        return binary.length;
        \\    } catch (err) {
        \\        console.error("load file failed:", path, err);
        \\        return 0;
        \\    }
        \\}
    ).*;

// 将存档字节编码为 Base64，保存到浏览器。
export var __em_js__zhu_file_save align(1) linksection("em_js") =
    (
        \\(const char *name, const unsigned char *data, int len)<::>{
        \\    const path = UTF8ToString(name);
        \\    let text = "";
        \\    for (let pos = data; pos < data + len; pos += 0x8000) {
        \\        const end = Math.min(pos + 0x8000, data + len);
        \\        const chars = new Array(end - pos);
        \\        for (let i = pos; i < end; i++) {
        \\            chars[i - pos] = String.fromCharCode(HEAPU8[i]);
        \\        }
        \\        text += chars.join("");
        \\    }
        \\    try {
        \\        window.localStorage.setItem(path, btoa(text));
        \\        return 0;
        \\    } catch (err) {
        \\        console.error("save file failed:", path, err);
        \\        return 1;
        \\    }
        \\}
    ).*;
