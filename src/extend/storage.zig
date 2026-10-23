//! 用户数据存储，目录按应用区分，由游戏在启动阶段单独初始化。
const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../internal/memory.zig");

var io: std.Io = undefined;
// 初始化时复制路径，避免保存启动环境变量中的借用切片。
var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
var dataPath: []const u8 = undefined;

/// 在游戏 main 中调用；name 是固定的应用数据名称，用于桌面目录和 Web 存储键。
/// 安卓和 iOS 使用应用沙盒，Web 使用 name 作为浏览器存储键的前缀。
pub fn init(info: std.process.Init, name: []const u8) void {
    io = info.io;
    const env = info.environ_map;
    dataPath = switch (builtin.os.tag) {
        .windows => memory.format(&pathBuffer, "{s}\\{s}", .{
            env.get("APPDATA") orelse @panic("APPDATA not set"),
            name,
        }),
        .linux => if (builtin.abi.isAndroid())
            @import("../internal/android.zig").dataPath()
        else if (env.get("XDG_DATA_HOME")) |data|
            memory.format(&pathBuffer, "{s}/{s}", .{ data, name })
        else
            memory.format(&pathBuffer, "{s}/.local/share/{s}", .{
                env.get("HOME") orelse @panic("HOME not set"),
                name,
            }),
        .macos => memory.format(&pathBuffer, "{s}/{s}/{s}", .{
            env.get("HOME") orelse @panic("HOME not set"),
            "Library/Application Support",
            name,
        }),
        .ios => memory.format(&pathBuffer, "{s}/{s}", .{
            env.get("HOME") orelse @panic("HOME not set"),
            "Library/Application Support",
        }),
        .emscripten => memory.format(&pathBuffer, "{s}", .{name}),
        else => return,
    };
}

/// 检查用户数据文件是否存在，路径相对于存储目录。
pub fn exists(path: [:0]const u8) bool {
    if (builtin.os.tag == .emscripten) return em.exists(path);
    const dir = std.Io.Dir.openDirAbsolute(io, dataPath, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// 读取用户数据，并在缓冲区末尾添加零字节。
pub fn readBuffer(path: [:0]const u8, buffer: []u8) ![:0]u8 {
    const buf = buffer[0 .. buffer.len - 1];
    if (builtin.os.tag == .emscripten) {
        return switch (try em.load(path, buf)) {
            .loaded => |content| terminateBuffer(buffer, content.len),
            .tooSmall => error.BufferTooSmall,
        };
    }
    const dir = try std.Io.Dir.openDirAbsolute(io, dataPath, .{});
    defer dir.close(io);
    const content = try dir.readFile(io, path, buf);
    return terminateBuffer(buffer, content.len);
}

/// 读取完整用户数据，由调用者释放返回的内存。
pub fn readAll(gpa: std.mem.Allocator, path: [:0]const u8) ![:0]u8 {
    if (builtin.os.tag == .emscripten) {
        var buffer: [1024]u8 = undefined;
        return switch (try em.load(path, &buffer)) {
            .loaded => |content| try gpa.dupeSentinel(u8, content, 0),
            .tooSmall => |len| readFromJs(gpa, path, len),
        };
    }
    const dir = try std.Io.Dir.openDirAbsolute(io, dataPath, .{});
    defer dir.close(io);
    return dir.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
}

/// 保存用户数据，首次写入时创建存储目录和文件所在的子目录。
pub fn saveAll(path: [:0]const u8, content: []const u8) !void {
    if (builtin.os.tag == .emscripten) return em.save(path, content);
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, dataPath, .{});
    defer dir.close(io);
    if (std.fs.path.dirname(path)) |sub| try dir.createDirPath(io, sub);

    var file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// 读取 JSON 存档；调用者通过 deinit 释放结果及其字符串和数组。
pub fn readJson(comptime T: type, path: [:0]const u8) !std.json.Parsed(T) {
    const gpa = memory.allocator.raw;
    const content = try readAll(gpa, path);
    defer gpa.free(content);
    // 解析结果拥有自己的数据，读取缓冲区在返回前即可释放。
    return std.json.parseFromSlice(T, gpa, content, .{ .allocate = .alloc_always });
}

/// 将数据序列化为 JSON 后保存，临时缓冲区在写入结束后释放。
pub fn saveJson(path: [:0]const u8, value: anytype) !void {
    const gpa = memory.allocator.raw;
    const content = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(content);
    try saveAll(path, content);
}

// 为读取结果补上零字节，返回的切片仍由原缓冲区持有。
fn terminateBuffer(buffer: []u8, len: usize) [:0]u8 {
    buffer[len] = 0;
    return buffer[0..len :0];
}

// 浏览器数据超过初始缓冲区时，按实际长度分配后重新读取。
fn readFromJs(gpa: std.mem.Allocator, path: [:0]const u8, len: usize) ![:0]u8 {
    const large = try gpa.alloc(u8, len + 1);
    errdefer gpa.free(large);
    return switch (try em.load(path, large[0..len])) {
        .loaded => |content| terminateBuffer(large, content.len),
        .tooSmall => error.BufferTooSmall,
    };
}

const em = struct {
    pub const Load = union(enum) { loaded: []u8, tooSmall: usize };

    // 浏览器存档函数由 web.c 中的 EM_JS 静态接入。
    extern fn zhu_file_keep() void;
    extern fn zhu_file_exists(path: [*:0]const u8) c_int;
    extern fn zhu_file_load(path: [*:0]const u8, out: [*]u8, len: c_int) c_int;
    extern fn zhu_file_save(path: [*:0]const u8, data: [*]const u8, len: c_int) c_int;

    /// 检查浏览器中是否存在存档。
    pub fn exists(path: [:0]const u8) bool {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        zhu_file_keep();
        return zhu_file_exists(key(&buffer, path).ptr) != 0;
    }

    /// 读取浏览器存档，将原始字节写入传入的缓冲区。
    pub fn load(path: [:0]const u8, buffer: []u8) !Load {
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        zhu_file_keep();
        const len = zhu_file_load(
            key(&keyBuffer, path).ptr,
            buffer.ptr,
            @intCast(buffer.len),
        );
        if (len == 0) return error.FileNotFound;
        if (len < 0) return .{ .tooSmall = @intCast(-len) };
        return .{ .loaded = buffer[0..@intCast(len)] };
    }

    /// 将存档字节编码为 Base64，保存到浏览器。
    pub fn save(path: [:0]const u8, data: []const u8) !void {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        zhu_file_keep();
        const err = zhu_file_save(
            key(&buffer, path).ptr,
            data.ptr,
            @intCast(data.len),
        );
        if (err != 0) return error.WriteFailed;
    }

    // 同一站点的不同游戏通过固定名称区分存档。
    fn key(buffer: []u8, path: [:0]const u8) [:0]u8 {
        return memory.formatZ(buffer, "{s}/{s}", .{ dataPath, path });
    }
};
