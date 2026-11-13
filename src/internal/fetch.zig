//! 文件加载、资源解码与 zlib 解压：路径去重、资源包和借用切片。
//! 原生后台读取和解码，主线程交付结果；Web 在主线程解码。
//! 基准随 Sokol 依赖更新；升级时检查上游差异并同步适用修复。
//! 上游基准（floooh/sokol）：
//! https://github.com/floooh/sokol/commit/efeb77603e24daea7d1dd6445b9358bb5d82533b
//! 对应 sokol-zig 提交：3990b6629704f988041ac7e76ed010348eabd098。
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const platform = @import("platform.zig");
const web = @import("web.zig");
const image = @import("image.zig");
const vorbis = @import("vorbis.zig");
const oom = @import("core.zig").oom;

pub const Id = u32;
pub fn id(path: []const u8) Id {
    return std.hash.Fnv1a_32.hash(path);
}

pub const Response = struct {
    path: [:0]const u8,
    content: union(Kind) {
        bytes: []const u8,
        zlib: []const u8, // 解压后的字节，回调结束后释放。
        image: image.Image,
        sound: vorbis.Sound,
    } = .{ .bytes = &.{} },
};
pub const Kind = enum { bytes, zlib, image, sound };
pub const Option = struct {
    kind: Kind = .bytes,
};
const Handler = *const fn (u64, Response) void;
const Request = struct {
    path: [:0]const u8,
    data: ?[]const u8 = null,
    index: u64,
    handler: Handler,
    option: Option,
};

const Slot = struct {
    state: std.atomic.Value(enum(u8) { idle, load, done }) = .init(.idle),
    request: Request = undefined,
    result: anyerror!Response = undefined,
    decoded: bool = false, // 原生端仅后台读写，用于统计未交付的解码结果。
    needsFree: bool = false, // 当前数据是否由槽位负责释放。

    fn freeResult(self: *Slot) void {
        if (!self.needsFree) return;
        defer self.needsFree = false;
        switch ((self.result catch return).content) {
            .bytes, .zlib => |data| gpa.free(data),
            .image => |decoded| gpa.free(decoded.data),
            .sound => |source| source.deinit(gpa),
        }
    }
};

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
// 仅主线程访问：切片表示待请求的借用数据，null 表示已经请求过。
var records: std.AutoHashMapUnmanaged(Id, ?[]const u8) = .empty;
var mapping: ?std.Io.File.MemoryMap = null;

// 仅主线程访问的等待队列。
var queue: std.Deque(Request) = .empty;
var slots: [4]Slot = @splat(.{}); // 每个槽位拥有独立缓冲区。
const isWeb = builtin.os.tag == .emscripten;
const MAX_DECODE = 2;
var started: bool = false; // 仅主线程读写加载器生命周期。

// 保存加载配置；append 模式映射包内数据，首次请求时启动后台线程。
pub fn init(fileIo: std.Io, gpa_: std.mem.Allocator) void {
    std.debug.assert(!started);
    io = fileIo;
    gpa = gpa_;
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
    records.ensureUnusedCapacity(gpa, fileCount) catch oom();
    for (0..fileCount) |i| {
        const entry = bytes[indexStart + i * 12 ..][0..12];
        const hash = std.mem.readInt(u32, entry[0..4], .little);
        const offset = start + std.mem.readInt(u32, entry[4..8], .little);
        const length = std.mem.readInt(u32, entry[8..12], .little);
        records.putAssumeCapacity(hash, bytes[offset..][0..length]);
    }
    std.log.info("loaded asset pack: {} files", .{fileCount});
}

// 只借用切片，调用方保留数据直到文件回调完成或文件模块销毁。
pub fn put(path: [:0]const u8, data: []const u8) void {
    const entry = records.getOrPut(gpa, id(path)) catch oom();
    std.debug.assert(!entry.found_existing);
    entry.value_ptr.* = data;
}

pub fn count() usize {
    return records.count();
}

// 同一路径只加载一次；所有请求排队，由 update 交付结果。
pub fn load(path: [:0]const u8, index: u64, handler: Handler, option: Option) void {
    const fileId = id(path);
    const entry = records.getOrPut(gpa, fileId) catch oom();
    var data: ?[]const u8 = null;
    if (entry.found_existing) {
        data = entry.value_ptr.* orelse
            std.debug.panic("asset already requested: {s}", .{path});
    } else if (options.append) {
        std.debug.panic("asset not found in pack: {s}", .{path});
    }
    entry.value_ptr.* = null;
    std.log.info("loading {s}", .{path});
    // 首次请求时启动加载器；Web 通过 JS 发起请求，不创建线程。
    if (!started) {
        if (!isWeb) Native.start();
        started = true;
    }
    queue.pushBack(gpa, .{
        .path = gpa.dupeSentinel(u8, path, 0) catch oom(),
        .data = data,
        .index = index,
        .handler = handler,
        .option = option,
    }) catch oom();
}

// 主线程接收结果并补充请求，回调可以继续提交资源加载。
pub fn update() void {
    if (!started) return;
    var needWake = false;
    for (&slots, 0..) |*slot, lane| blk: switch (slot.state.load(.acquire)) {
        .done => {
            const request = slot.request;
            const path = request.path;
            const response = slot.result catch |err| {
                const msg = "assets load failed, path: {s}, error: {}";
                std.debug.panic(msg, .{ path, err });
            };
            std.log.info("loaded: {s}", .{path});
            request.handler(request.index, response);
            if (request.option.kind == .sound) {
                slot.needsFree = false; // 音效由资产管理。
            }
            slot.freeResult();
            gpa.free(path);
            slot.state.store(.idle, .release);
            needWake = true;
            continue :blk .idle;
        },
        .idle => {
            const request = queue.popFront() orelse continue;
            slot.request = request;
            slot.needsFree = false;
            slot.state.store(.load, .release);
            needWake = true;
            if (!isWeb) continue;
            if (request.data) |data| decodeSlot(slot, data) else //
            web.zhu_fetch_start(@intCast(lane), request.path.ptr);
        },
        else => {},
    };
    if (!isWeb and needWake) Native.wake.set(io);
}

// 先等待读取线程退出，再释放仍在途的路径和缓冲区。
fn shutdown() void {
    if (!started) return;
    if (isWeb) web.zhu_fetch_stop() else Native.stop();
    while (queue.popFront()) |request| gpa.free(request.path);
    queue.deinit(gpa);
    queue = .empty;
    for (&slots) |*slot| {
        const state = slot.state.load(.acquire);
        if (state != .idle) {
            gpa.free(slot.request.path);
            slot.freeResult();
        }
        slot.* = .{};
    }
    started = false;
}

// 先停止读取，再释放记录和包内数据的共同所有者。
pub fn deinit() void {
    shutdown();
    records.deinit(gpa);
    records = .empty;
    if (mapping) |*mapped| {
        const exe = mapped.file;
        mapped.destroy(io);
        exe.close(io);
        mapping = null;
    }
}

// 读取完成后直接解码，再由主线程交付结果。
fn decodeSlot(slot: *Slot, data: []const u8) void {
    slot.decoded = slot.request.option.kind != .bytes;
    slot.result = decode(slot, data);
    slot.state.store(.done, .release);
}

// 解码产生独立结果；原始字节只释放自己分配的部分。
fn decode(slot: *Slot, data: []const u8) !Response {
    const request = slot.request;
    const freeRaw = slot.needsFree and request.option.kind != .bytes;
    defer if (freeRaw) gpa.free(data);
    var result: Response = .{ .path = request.path };
    switch (request.option.kind) {
        .bytes => result.content = .{ .bytes = data },
        .zlib => {
            var input = std.Io.Reader.fixed(data);
            const buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(buffer);
            var decoder = std.compress.flate.Decompress.init(&input, .zlib, buffer);
            const bytes = try decoder.reader.allocRemaining(gpa, .unlimited);
            slot.needsFree = true;
            result.content = .{ .zlib = bytes };
        },
        .image => {
            const decoded = try image.loadIcon(gpa, data);
            slot.needsFree = true;
            result.content = .{ .image = decoded };
        },
        .sound => {
            const source = try vorbis.Sound.init(gpa, data);
            slot.needsFree = true;
            result.content = .{ .sound = source };
        },
    }
    return result;
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

// 与主线程通过槽位状态交接所有权，保持一个后台读取线程。
fn runBackground() void {
    while (true) {
        Native.wake.waitUncancelable(io);
        Native.wake.reset();
        if (Native.stopping.load(.acquire)) return;
        // 主线程只会释放结果，扫描期间数量可以保守地偏大。
        var decoding: u32 = 0;
        for (&slots) |*slot| {
            if (slot.state.load(.acquire) != .done) continue;
            if (slot.decoded) decoding += 1;
        }
        for (&slots) |*slot| {
            if (Native.stopping.load(.acquire)) return;
            if (slot.state.load(.acquire) != .load) continue;
            const needsDecode = slot.request.option.kind != .bytes;
            if (needsDecode and decoding >= MAX_DECODE) continue;
            const data = readRequest(slot.request) catch |err| {
                slot.decoded = false;
                slot.result = err;
                slot.state.store(.done, .release);
                continue;
            };
            slot.needsFree = slot.request.data == null;
            decodeSlot(slot, data);
            if (needsDecode) decoding += 1;
        }
    }
}

fn readRequest(request: Request) ![]const u8 {
    if (request.data) |data| return data;
    if (!builtin.abi.isAndroid() and Native.assetDir == null) {
        Native.assetDir = try openAssetDir();
    }
    return platform.readFile(gpa, Native.assetDir, request.path);
}

// 原生平台唤醒后台线程，读取和解码共用槽位状态。
const Native = struct {
    // 首次读取外部文件时打开，后台线程退出后关闭。
    var assetDir: ?std.Io.Dir = null;
    var worker: ?std.Thread = null;
    var wake: std.Io.Event = .unset;
    var stopping: std.atomic.Value(bool) = .init(false);

    fn start() void {
        worker = std.Thread.spawn(.{}, runBackground, .{}) catch |err|
            std.debug.panic("start asset reader: {}", .{err});
    }

    fn stop() void {
        stopping.store(true, .release);
        wake.set(io);
        worker.?.join();
        worker = null;
        if (assetDir) |dir| dir.close(io);
        assetDir = null;
        stopping.store(false, .release);
        wake.reset();
    }
};

// 浏览器拿到响应后直接为请求槽位分配缓冲区。
fn webAlloc(lane: c_int, size: usize) callconv(.c) [*]u8 {
    const data = gpa.alloc(u8, size) catch @panic("out of memory");
    const slot = &slots[@intCast(lane)];
    slot.result = .{ .path = slot.request.path, .content = .{ .bytes = data } };
    slot.needsFree = true;
    return data.ptr;
}

// 浏览器下载完成后直接解码，结果等待 update 交付。
fn webDone(lane: c_int, status: c_int) callconv(.c) void {
    const slot = &slots[@intCast(lane)];
    if (status == 0) {
        const raw = slot.result catch unreachable;
        return decodeSlot(slot, raw.content.bytes);
    }
    slot.freeResult();
    slot.result = error.HttpFailed; // 不区分错误类型
    slot.state.store(.done, .release);
}

comptime {
    if (isWeb) {
        @export(&webAlloc, .{ .name = "zhu_fetch_alloc" });
        @export(&webDone, .{ .name = "zhu_fetch_done" });
    }
}
