//! 整文件异步加载，参考 sokol_fetch.h 的请求调度和主线程回调。
//! 基准随 Sokol 依赖更新；升级时检查上游差异并同步适用修复。
//! 上游基准（floooh/sokol）：
//! https://github.com/floooh/sokol/commit/efeb77603e24daea7d1dd6445b9358bb5d82533b
//! 对应 sokol-zig 提交：3990b6629704f988041ac7e76ed010348eabd098。
const std = @import("std");
const builtin = @import("builtin");

const android = @import("android.zig");
const web = @import("web.zig");

pub const Response = struct {
    path: [:0]const u8,
    buffer: []u8, // 缓冲区交给回调，回调负责保留或释放。
    result: anyerror![]const u8,
};

const Request = struct {
    path: [:0]const u8, // 提交时复制，回调结束后释放。
    callback: *const fn (Response) void,
};

const Slot = struct {
    state: std.atomic.Value(enum(u8) { idle, queued, done }) = .init(.idle),
    request: Request = undefined,
    buffer: []u8 = &.{},
    result: anyerror![]const u8 = undefined,
};

var allocator: std.mem.Allocator = undefined;
var io: std.Io = undefined;
var assetDir: std.Io.Dir = undefined; // 首次请求时打开，读取线程退出后关闭。
var requests: std.ArrayList(Request) = .empty; // 仅主线程访问的等待队列。
var nextRequest: usize = 0;
var slots: [4]Slot = @splat(.{}); // 每个槽位拥有独立缓冲区。
var worker: ?std.Thread = null;
var wake: std.Io.Event = .unset;
var stop: std.atomic.Value(bool) = .init(false);
var started: bool = false; // 仅主线程读写加载器生命周期。

// 只保存加载配置，不打开目录或启动线程。
pub fn setup(fileIo: std.Io, gpa: std.mem.Allocator) void {
    std.debug.assert(!started);
    io = fileIo;
    allocator = gpa;
}

// 优先打开当前目录的 assets，失败时使用可执行文件旁的目录。
fn openAssetDir() !std.Io.Dir {
    const curDir = std.Io.Dir.cwd().openDir(io, "assets", .{});
    if (curDir) |dir| return dir else |_| {}

    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executableDirPath(io, &path);
    const exeDir = try std.Io.Dir.openDirAbsolute(io, path[0..len], .{});
    defer exeDir.close(io);
    return exeDir.openDir(io, "assets", .{});
}

// 主线程登记路径和请求队列，文件内容由后台按实际长度分配。
pub fn send(path: [:0]const u8, callback: *const fn (Response) void) void {
    // 首次请求时启动加载器；Web 通过 JS 发起请求，不创建线程。
    if (!started) {
        if (builtin.os.tag != .emscripten) {
            if (!builtin.abi.isAndroid()) {
                assetDir = openAssetDir() catch |err|
                    std.debug.panic("open assets directory: {}", .{err});
            }
            worker = std.Thread.spawn(.{}, run, .{}) catch |err|
                std.debug.panic("start asset reader: {}", .{err});
        }
        started = true;
    }
    const owned = allocator.dupeSentinel(u8, path, 0) catch
        @panic("out of memory");
    requests.append(allocator, .{ .path = owned, .callback = callback }) catch
        @panic("out of memory");
}

// 主线程接收结果并补充请求，回调可以继续提交资源加载。
pub fn dowork() void {
    if (!started) return;
    for (&slots, 0..) |*slot, lane| {
        if (slot.state.load(.acquire) == .done) {
            const request = slot.request;
            const buffer = slot.buffer;
            slot.buffer = &.{};
            request.callback(.{
                .path = request.path,
                .buffer = buffer,
                .result = slot.result,
            });
            allocator.free(request.path);
            slot.state.store(.idle, .release);
        }
        if (slot.state.load(.acquire) != .idle) continue;
        if (nextRequest == requests.items.len) continue;
        slot.request = requests.items[nextRequest];
        nextRequest += 1;
        slot.state.store(.queued, .release);
        if (builtin.os.tag == .emscripten) {
            web.zhu_fetch_start(@intCast(lane), slot.request.path.ptr);
        } else {
            wake.set(io);
        }
    }
    if (nextRequest == requests.items.len) {
        requests.clearRetainingCapacity();
        nextRequest = 0;
    }
}

// 先等待读取线程退出，再释放仍在途的路径和缓冲区。
pub fn shutdown() void {
    if (!started) return;
    if (builtin.os.tag == .emscripten) {
        web.zhu_fetch_stop();
    } else {
        stop.store(true, .release);
        wake.set(io);
        worker.?.join();
        worker = null;
        if (!builtin.abi.isAndroid()) assetDir.close(io);
    }
    for (requests.items[nextRequest..]) |request| allocator.free(request.path);
    requests.deinit(allocator);
    requests = .empty;
    nextRequest = 0;
    for (&slots) |*slot| {
        if (slot.state.load(.acquire) == .idle) continue;
        allocator.free(slot.request.path);
        allocator.free(slot.buffer);
        slot.* = .{};
    }
    stop.store(false, .release);
    wake.reset();
    started = false;
}

// 与主线程通过槽位状态交接所有权，保持一个后台读取线程。
fn run() void {
    while (true) {
        wake.waitUncancelable(io);
        wake.reset();
        if (stop.load(.acquire)) return;
        for (&slots) |*slot| {
            if (stop.load(.acquire)) return;
            if (slot.state.load(.acquire) != .queued) continue;
            const data = read(slot.request.path) catch |err| {
                slot.result = err;
                slot.state.store(.done, .release);
                continue;
            };
            slot.buffer = data;
            slot.result = data;
            slot.state.store(.done, .release);
        }
    }
}

// 后台打开文件，按实际长度分配并读取，回调接收缓冲的所有权。
fn read(path: [:0]const u8) ![]u8 {
    if (builtin.abi.isAndroid()) return android.readAsset(path, allocator);
    const file = try assetDir.openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);
    if (try file.readPositionalAll(io, buffer, 0) != size) {
        return error.UnexpectedEof;
    }
    return buffer;
}

// 浏览器拿到响应后直接为请求槽位分配缓冲区。
fn webAlloc(lane: c_int, size: usize) callconv(.c) [*]u8 {
    const slot = &slots[@intCast(lane)];
    slot.buffer = allocator.alloc(u8, size) catch @panic("out of memory");
    return slot.buffer.ptr;
}

// 浏览器只登记完成结果，资源回调仍由下一帧 dowork 执行。
fn webDone(lane: c_int, size: c_int, status: c_int) callconv(.c) void {
    const slot = &slots[@intCast(lane)];
    slot.result = switch (status) {
        0 => slot.buffer[0..@intCast(size)],
        1 => error.HttpFailed,
        3 => error.NetworkFailed,
        else => unreachable,
    };
    slot.state.store(.done, .release);
}

comptime {
    if (builtin.os.tag == .emscripten) {
        @export(&webAlloc, .{ .name = "zhu_fetch_alloc" });
        @export(&webDone, .{ .name = "zhu_fetch_done" });
    }
}
