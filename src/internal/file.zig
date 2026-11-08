//! 原始文件加载：路径去重、资源包和借用切片。
//! 外部文件由四个槽位异步读取。
//! 基准随 Sokol 依赖更新；升级时检查上游差异并同步适用修复。
//! 上游基准（floooh/sokol）：
//! https://github.com/floooh/sokol/commit/efeb77603e24daea7d1dd6445b9358bb5d82533b
//! 对应 sokol-zig 提交：3990b6629704f988041ac7e76ed010348eabd098。
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const oom = @import("core.zig").oom;

const android = @import("android.zig");
const web = @import("web.zig");

pub const Id = u32;
pub fn id(path: []const u8) Id {
    return std.hash.Fnv1a_32.hash(path);
}

pub const Response = struct {
    path: [:0]const u8,
    data: []const u8,
};
const Handler = *const fn (index: u64, resp: Response) void;
const FileState = enum { loading, loaded, handled };
const FileCache = struct {
    state: FileState = .loading,
    index: u64 = 0,
    data: []const u8 = &.{},
    handler: Handler = undefined,
};

var cache: std.AutoHashMapUnmanaged(Id, FileCache) = .empty;
var mapping: ?std.Io.File.MemoryMap = null;

const Slot = struct {
    state: std.atomic.Value(enum(u8) { idle, queued, done }) = .init(.idle),
    path: [:0]const u8 = undefined,
    result: anyerror![]u8 = &.{},
};

var allocator: std.mem.Allocator = undefined;
var io: std.Io = undefined;
// 首次请求时打开，读取线程退出后关闭。
var assetDir: std.Io.Dir = undefined;
// 仅主线程访问的等待队列。
var requests: std.ArrayList([:0]const u8) = .empty;
var nextRequest: usize = 0;
var slots: [4]Slot = @splat(.{}); // 每个槽位拥有独立缓冲区。
var worker: ?std.Thread = null;
var wake: std.Io.Event = .unset;
var stop: std.atomic.Value(bool) = .init(false);
var started: bool = false; // 仅主线程读写加载器生命周期。

// 保存加载配置；append 模式映射包内数据，外部读取仍按需启动。
pub fn init(fileIo: std.Io, gpa: std.mem.Allocator) void {
    std.debug.assert(!started);
    io = fileIo;
    allocator = gpa;
    if (options.append) initExecutable() catch |err| {
        std.debug.panic("asset pack init failed: {}", .{err});
    };
}

fn initExecutable() !void {
    const exe = try std.process.openExecutable(io, .{});
    errdefer exe.close(io);
    const stat = try exe.stat(io);
    var mapped = try exe.createMemoryMap(io, .{
        .len = @intCast(stat.size),
        .protection = .{ .read = true },
        .populate = false,
    });
    errdefer mapped.destroy(io);
    const bytes = mapped.memory;
    if (!std.mem.endsWith(u8, bytes, "b0b0")) return error.AssetPackNotFound;
    initPack(bytes);
    mapping = mapped;
}

// 借用有效资源包，调用方保留字节直到文件模块销毁。
pub fn initPack(bytes: []const u8) void {
    std.debug.assert(std.mem.endsWith(u8, bytes, "b0b0"));
    const footer = bytes[bytes.len - 12 ..];
    const fileCount = std.mem.readInt(u32, footer[0..4], .little);
    const size = std.mem.readInt(u32, footer[4..8], .little);
    const start = bytes.len - size;
    const indexStart = bytes.len - 12 - fileCount * 12;
    cache.ensureUnusedCapacity(allocator, fileCount) catch oom();
    for (0..fileCount) |i| {
        const entry = bytes[indexStart + i * 12 ..][0..12];
        const hash = std.mem.readInt(u32, entry[0..4], .little);
        const offset = start + std.mem.readInt(u32, entry[4..8], .little);
        const length = std.mem.readInt(u32, entry[8..12], .little);
        cache.putAssumeCapacity(hash, .{
            .state = .loaded,
            .data = bytes[offset..][0..length],
        });
    }
    std.log.info("loaded asset pack: {} files", .{fileCount});
}

// 只借用切片，调用方保留数据直到文件回调完成或文件模块销毁。
pub fn put(path: [:0]const u8, data: []const u8) void {
    const entry = cache.getOrPut(allocator, id(path)) catch oom();
    std.debug.assert(!entry.found_existing);
    entry.value_ptr.* = .{ .state = .loaded, .data = data };
}

pub fn count() usize {
    return cache.count();
}

// 同一路径只加载一次；借用数据同步回调，外部文件排队读取。
pub fn load(path: [:0]const u8, index: u64, handler: Handler) *FileCache {
    const fileId = id(path);
    const entry = cache.getOrPut(allocator, fileId) catch oom();
    const value = entry.value_ptr;
    if (entry.found_existing) {
        if (value.state == .loaded) {
            value.index = index;
            value.handler = handler;
            handleLoaded(path, value, value.data);
            return cache.getPtr(fileId).?;
        }
        // 已评审：资源按用途使用独立路径，图集页面与 icon 不共用文件。
        // 当前资源缓存到退出，同一路径只绑定一组 index/handler，不支持重新加载。
        // 此检查是有意的使用约束；引入资源卸载后再调整，无需为跨用途复用扩展。
        if (value.index != index or value.handler != handler) {
            std.debug.panic("asset path conflict: {s}", .{path});
        }
        return value;
    }
    if (options.append) {
        std.debug.panic("asset not found in appended pack: {s}", .{path});
    }
    value.* = .{ .index = index, .handler = handler };
    std.log.info("loading {s}", .{path});
    enqueue(path);
    return value;
}

// 先完成文件记录，再执行回调，回调可以继续加载其他文件。
fn handleLoaded(path: [:0]const u8, value: *FileCache, data: []const u8) void {
    const handler = value.handler;
    const index = value.index;
    const response: Response = .{ .path = path, .data = data };
    value.state = .handled;
    value.data = &.{};
    handler(index, response);
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
fn enqueue(path: [:0]const u8) void {
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
    requests.append(allocator, owned) catch @panic("out of memory");
}

// 主线程接收结果并补充请求，回调可以继续提交资源加载。
pub fn update() void {
    if (!started) return;
    for (&slots, 0..) |*slot, lane| {
        handleSlot(slot);
        if (slot.state.load(.acquire) != .idle) continue;
        if (nextRequest == requests.items.len) continue;

        // 空闲槽位接收下一个请求，交给后台线程或浏览器读取。
        slot.path = requests.items[nextRequest];
        nextRequest += 1;
        slot.state.store(.queued, .release);
        if (builtin.os.tag == .emscripten) {
            web.zhu_fetch_start(@intCast(lane), slot.path.ptr);
        } else {
            wake.set(io);
        }
    }
    // 等待队列已全部派发，清空记录并保留容量。
    if (nextRequest == requests.items.len) {
        requests.clearRetainingCapacity();
        nextRequest = 0;
    }
}

// 在主线程处理已完成的请求，回调可以继续提交新请求。
fn handleSlot(slot: *Slot) void {
    if (slot.state.load(.acquire) != .done) return;
    const path = slot.path;
    const data = slot.result catch |err| {
        const msg = "assets load failed, path: {s}, error: {}";
        std.debug.panic(msg, .{ path, err });
    };
    slot.result = &.{};
    std.log.info("loaded: {s}", .{path});
    handleLoaded(path, cache.getPtr(id(path)).?, data);
    allocator.free(data);
    allocator.free(path);
    slot.state.store(.idle, .release);
}

// 先等待读取线程退出，再释放仍在途的路径和缓冲区。
fn shutdown() void {
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
    for (requests.items[nextRequest..]) |path| allocator.free(path);
    requests.deinit(allocator);
    requests = .empty;
    nextRequest = 0;
    for (&slots) |*slot| {
        if (slot.state.load(.acquire) == .idle) continue;
        allocator.free(slot.path);
        allocator.free(slot.result catch &.{});
        slot.* = .{};
    }
    stop.store(false, .release);
    wake.reset();
    started = false;
}

// 先停止读取，再释放记录和包内数据的共同所有者。
pub fn deinit() void {
    shutdown();
    cache.deinit(allocator);
    cache = .empty;
    if (mapping) |*mapped| {
        const exe = mapped.file;
        mapped.destroy(io);
        exe.close(io);
        mapping = null;
    }
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
            slot.result = read(slot.path);
            slot.state.store(.done, .release);
        }
    }
}

// 后台按实际长度分配并读取，缓冲在主线程回调后释放。
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
    const data = allocator.alloc(u8, size) catch @panic("out of memory");
    slots[@intCast(lane)].result = data;
    return data.ptr;
}

// 浏览器只登记完成结果，资源回调仍由下一帧 update 执行。
fn webDone(lane: c_int, status: c_int) callconv(.c) void {
    const slot = &slots[@intCast(lane)];
    slot.result = switch (status) {
        0 => slot.result,
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
