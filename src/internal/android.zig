const std = @import("std");
const root = @import("root");
const sk = @import("sokol");

// 对应 NDK android/native_activity.h，保持完整字段顺序和 C 内存布局。
const Activity = extern struct {
    callbacks: ?*anyopaque,
    vm: ?*anyopaque,
    env: ?*anyopaque,
    clazz: ?*anyopaque,
    internalDataPath: [*:0]const u8,
    externalDataPath: ?[*:0]const u8,
    sdkVersion: i32,
    instance: ?*anyopaque,
    assetManager: ?*anyopaque,
    obbPath: ?[*:0]const u8,
};

// 游戏回调继续使用 IO，窗口配置由 window.run 写入后返回给 Sokol。
pub var threaded: std.Io.Threaded = undefined;
pub var desc: ?sk.app.Desc = null;

// NDK 管理的不透明配置对象。
const Configuration = opaque {};

extern fn AConfiguration_new() *Configuration;
extern fn AConfiguration_delete(*Configuration) void;
extern fn AConfiguration_fromAssetManager(*Configuration, ?*anyopaque) void;
extern fn AConfiguration_getDensity(*Configuration) i32;

// 从安卓配置读取界面密度，1 表示每个界面单位对应一个窗口像素。
pub fn density() f32 {
    const activity: *const Activity =
        @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
    const config = AConfiguration_new();
    defer AConfiguration_delete(config);
    AConfiguration_fromAssetManager(config, activity.assetManager);
    const value = AConfiguration_getDensity(config);
    return @as(f32, @floatFromInt(value)) / 160.0;
}

extern fn AAssetManager_open(?*anyopaque, [*:0]const u8, c_int) ?*anyopaque;
extern fn AAsset_getLength64(*anyopaque) i64;
extern fn AAsset_read(*anyopaque, [*]u8, usize) c_int;
extern fn AAsset_close(*anyopaque) void;

// 后台线程直接读取 APK 资源，避免 FILE 和 funopen 的中转。
pub fn readAsset(path: [:0]const u8, buffer: []u8) ![]const u8 {
    const activity: *const Activity =
        @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
    const asset = AAssetManager_open(activity.assetManager, path, 2) orelse
        return error.FileNotFound;
    defer AAsset_close(asset);
    const size: usize = @intCast(AAsset_getLength64(asset));
    if (size > buffer.len) return error.BufferTooSmall;
    const data = buffer[0..size];
    // AAsset_read 返回本次读取量，持续读取到文件声明的长度。
    var offset: usize = 0;
    while (offset < data.len) {
        const count = AAsset_read(asset, data[offset..].ptr, data.len - offset);
        if (count < 0) return error.ReadFailed;
        if (count == 0) return error.UnexpectedEof;
        offset += @intCast(count);
    }
    return data;
}

// 初始化安卓运行环境，再调用游戏入口取得窗口配置。
export fn sokol_main(_: c_int, _: ?*?[*:0]u8) sk.app.Desc {
    const gpa = std.heap.c_allocator;
    threaded = .init(gpa, .{});

    const activity: *const Activity =
        @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
    // 进入游戏 main 前切换目录，普通文件读写使用应用私有空间。
    const path = std.mem.span(activity.internalDataPath);
    std.process.setCurrentPath(threaded.io(), path) catch |err|
        std.debug.panic("android private directory: {}", .{err});

    // 只供 main 初始化阶段使用。
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const result = root.main(.{
        .minimal = .{
            .args = .{ .vector = &.{} },
            .environ = .empty,
        },
        .arena = &arena,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    });
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        _ = result catch |e| std.debug.panic("android main: {}", .{e});
    }
    return desc orelse @panic("android main must call window.run()");
}

extern fn __android_log_write(
    priority: c_int,
    tag: [*:0]const u8,
    text: [*:0]const u8,
) c_int;

extern fn __android_log_assert(
    condition: ?[*:0]const u8, // 传 null，直接使用格式化消息。
    tag: [*:0]const u8,
    format: [*:0]const u8,
    ...,
) noreturn;

// 将标准库日志直接写入 Logcat，只保留等级和消息。
pub fn log(
    comptime level: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = comptime level.asText() ++ ": ";
    // 对应 Android 的 ERROR、WARN、INFO、DEBUG 等级。
    const priority: c_int = switch (level) {
        .err => 6,
        .warn => 5,
        .info => 4,
        .debug => 3,
    };
    var buffer: [4000]u8 = undefined;
    const message = std.mem.printSentinel(&buffer, //
        prefix ++ format, args, 0) catch {
        const suffix = "...[truncated]";
        @memcpy(buffer[buffer.len - suffix.len - 1 ..][0..suffix.len], suffix);
        buffer[buffer.len - 1] = 0;
        _ = __android_log_write(priority, "ZhuYu", @ptrCast(&buffer));
        return;
    };
    _ = __android_log_write(priority, "ZhuYu", message);
}

// 显式 panic 和 Zig 安全检查统一使用安卓的崩溃输出。
pub const panic = std.debug.FullPanic(panicMessage);

fn panicMessage(message: []const u8, _: ?usize) noreturn {
    __android_log_assert(
        null,
        "ZhuYu",
        "panic: %.*s",
        @as(c_int, @intCast(message.len)),
        message.ptr,
    );
}
