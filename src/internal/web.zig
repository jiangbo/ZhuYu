//! 浏览器宿主接口，JavaScript 实现位于 web.js，通过 --js-library 注入。
const std = @import("std");

const zhu = @import("../zhu.zig");
const DateTime = @import("platform.zig").DateTime;
const dynamic = @import("../text.zig").dynamic;

const Allocator = std.mem.Allocator;

pub fn setup(_: std.mem.Allocator) void {}

// 应用名称作为浏览器存储键前缀，借用公共层持有的路径缓冲。
pub fn dataPath(_: std.process.Init, name: []const u8, buf: []u8) []const u8 {
    storage.dataName = zhu.format(buf, "{s}", .{name});
    return storage.dataName;
}

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
    var dataName: []const u8 = "";

    pub fn exists(path: []const u8) bool {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return existsKey(key(&buf, path));
    }

    pub fn readBuffer(path: []const u8, buf: []u8) ![]u8 {
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const result = try load(key(&keyBuffer, path), buf);
        return switch (result) {
            .loaded => |content| content,
            .tooSmall => error.BufferTooSmall,
        };
    }

    pub fn readAll(gpa: Allocator, path: []const u8) ![]u8 {
        var buf: [4096]u8 = undefined;
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pathKey = key(&keyBuffer, path);
        return switch (try load(pathKey, &buf)) {
            .loaded => |content| try gpa.dupe(u8, content),
            .tooSmall => |len| blk: {
                const large = try gpa.alloc(u8, len);
                errdefer gpa.free(large);
                switch (try load(pathKey, large)) {
                    .loaded => break :blk large,
                    .tooSmall => return error.BufferTooSmall,
                }
            },
        };
    }

    pub fn writeAll(path: []const u8, content: []const u8) !void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try save(key(&buf, path), content);
    }

    fn key(buf: []u8, path: []const u8) [:0]u8 {
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

// 打开、关闭浏览器字体，并读取像素度量和字形数据。
pub extern "env" fn zhu_font_open([*:0]const u8, u32) c_int;
pub extern "env" fn zhu_font_close() void;
pub extern "env" fn zhu_font_metrics(f32, *dynamic.Metrics) void;
pub extern "env" fn zhu_font_pixels(u32, *dynamic.Char, [*]u8, u32) c_int;

// 浏览器请求的发起与取消；请求状态和缓冲区由加载器持有。
pub extern fn zhu_fetch_start(lane: c_int, path: [*:0]const u8) void;
pub extern fn zhu_fetch_stop() void;
