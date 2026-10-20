const std = @import("std");

const sk = @import("sokol");
const c = @import("internal/c.zig");
const graphics = @import("graphics.zig");
const audio = @import("audio.zig");
const png = @import("internal/png.zig");
const memory = @import("internal/memory.zig");

const oom = memory.oom;
const Image = graphics.Image;
const Vector2 = graphics.Vector2;
const Filter = graphics.Filter;
const Path = [:0]const u8;
const assetRoot = "assets/";

var allocator: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
var imageCache: std.AutoHashMapUnmanaged(Id, graphics.Image) = .empty;
var maxFileSize: usize = 0;

pub fn init(io_: std.Io, maxSize: usize) void {
    io = io_;
    allocator = memory.allocator.raw;
    maxFileSize = maxSize;

    // 三个桌面系统都自动识别程序末尾的资源包。
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .macos or
        (builtin.os.tag == .linux and !builtin.abi.isAndroid()))
    {
        file.init() catch |err| {
            std.debug.panic("asset pack init failed: {}", .{err});
        };
    }

    sampler.init();
}

pub fn deinit() void {
    imageCache.deinit(allocator);
    atlas.cache.deinit(allocator);
    view.cache.deinit(allocator);
    sound.deinit();
    music.deinit();
    file.deinit();
    if (sk.fetch.valid()) sk.fetch.shutdown();
    for (&fileBuffer) |buf| if (buf.len != 0) allocator.free(buf);
    gpu.deinit();
    sk.gfx.destroySampler(sampler.nearest);
    sk.gfx.destroySampler(sampler.linear);
}

pub const ImageOption = struct {
    size: Vector2, // 图片尺寸，加载完成后验证
    filter: Filter = .nearest, // 纹理过滤方式
};

pub fn loadImage(path: Path, option: ImageOption) Image {
    const smp = sampler.get(option.filter);
    const entry = imageCache.getOrPut(allocator, id(path)) catch oom();
    if (entry.found_existing) {
        std.debug.assert(entry.value_ptr.sampler.id == smp.id);
        return entry.value_ptr.*;
    }

    const imageView = sk.gfx.allocView();
    entry.value_ptr.* = .{
        .view = imageView,
        .sampler = smp,
        .size = option.size,
    };
    view.cache.put(allocator, id(path), imageView) catch oom();
    _ = file.load(path, imageView.id, view.handler);
    return entry.value_ptr.*;
}

pub fn loadSound(path: Path, o: audio.Sound.Option) audio.Sound {
    return sound.load(path, o);
}

pub fn loadMusic(path: Path, loop: bool) ?*c.stbAudio.Audio {
    return music.load(path, loop);
}

pub const Id = u32;
pub fn id(name: []const u8) Id {
    return std.hash.Fnv1a_32.hash(name);
}

pub fn loadAtlas(source: graphics.Atlas, filter: graphics.Filter) void {
    atlas.load(source, sampler.get(filter));
}

pub fn getImage(imageId: Id) ?graphics.Image {
    return imageCache.get(imageId);
}

pub fn getImageByPath(comptime path: Path) ?graphics.Image {
    return getImage(id(path));
}

pub fn putImage(imageId: Id, image: graphics.Image) void {
    imageCache.put(allocator, imageId, image) catch oom();
}

pub const sampler = struct {
    pub var nearest: sk.gfx.Sampler = .{}; // 最近邻采样器
    pub var linear: sk.gfx.Sampler = .{}; // 线性采样器

    fn init() void {
        nearest = sk.gfx.makeSampler(.{
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
        });
        linear = sk.gfx.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
        });
    }

    // 返回过滤方式对应的采样器。
    pub fn get(filter: graphics.Filter) sk.gfx.Sampler {
        return switch (filter) {
            .nearest => nearest,
            .linear => linear,
        };
    }
};

pub const gpu = struct {
    var pipelines: std.ArrayListUnmanaged(sk.gfx.Pipeline) = .empty;
    var shaders: std.ArrayListUnmanaged(sk.gfx.Shader) = .empty;

    // 登记由引擎统一销毁的流水线。
    pub fn addPipeline(value: sk.gfx.Pipeline) void {
        pipelines.append(allocator, value) catch oom();
    }

    // 登记由引擎统一销毁的着色器。
    pub fn addShader(value: sk.gfx.Shader) void {
        shaders.append(allocator, value) catch oom();
    }

    fn deinit() void {
        for (pipelines.items) |value| sk.gfx.destroyPipeline(value);
        pipelines.deinit(allocator);

        for (shaders.items) |value| sk.gfx.destroyShader(value);
        shaders.deinit(allocator);
    }
};

const atlas = struct {
    var cache: std.AutoHashMapUnmanaged(Id, i32) = .empty;

    // 打包为文件加载回调的 64 位标识。
    const PageIndex = packed struct(u64) { atlasId: Id, layer: i32 };

    fn load(source: graphics.Atlas, smp: sk.gfx.Sampler) void {
        const atlasId = id(source.imagePaths[0]);
        const entry = cache.getOrPut(allocator, atlasId) catch oom();
        if (entry.found_existing) {
            std.debug.assert(imageCache.get(atlasId).?.sampler.id == smp.id);
            return;
        }

        const atlasView = sk.gfx.makeView(.{
            .texture = .{ .image = sk.gfx.makeImage(.{
                .usage = .{ .write_unsealed = true },
                .width = @intFromFloat(source.size.x),
                .height = @intFromFloat(source.size.y),
                .type = .ARRAY,
                .num_slices = @intCast(source.imagePaths.len),
            }) },
        });
        entry.value_ptr.* = 0;

        const len: u32 = @intCast(source.imagePaths.len + source.images.len);
        imageCache.ensureUnusedCapacity(allocator, len) catch oom();
        for (source.imagePaths, 0..) |path, i| {
            imageCache.putAssumeCapacity(id(path), .{
                .view = atlasView,
                .sampler = smp,
                .layer = @floatFromInt(i),
                .offset = .zero,
                .size = source.size,
            });

            const pageIndex = PageIndex{
                .atlasId = atlasId,
                .layer = @intCast(i),
            };
            _ = file.load(path, @bitCast(pageIndex), handler);
        }

        for (source.images) |image| {
            var img = image;
            img.view = atlasView;
            img.sampler = smp;
            imageCache.putAssumeCapacity(image.view.id, img);
        }
    }

    fn handler(response: Response) bool {
        const pageIndex: PageIndex = @bitCast(response.index);
        const atlasView = imageCache.get(pageIndex.atlasId).?.view;
        const atlasImage = sk.gfx.queryViewImage(atlasView);
        const img = png.load(allocator, response.data) catch |err| {
            std.debug.panic("{s}: {}", .{ response.path, err });
        };
        defer allocator.free(img.data);

        std.debug.assert(img.width == sk.gfx.queryImageWidth(atlasImage));
        std.debug.assert(img.height == sk.gfx.queryImageHeight(atlasImage));

        sk.gfx.writeImageUnsealed(.{
            .src = .{ .data = sk.gfx.asRange(img.data) },
            .dst = .{ .image = atlasImage, .slice = pageIndex.layer },
            // 零值表示从当前图层写到最后一层，这里只写本次加载的图层。
            .size = .{ .num_slices = 1 },
        });

        const count = cache.getPtr(pageIndex.atlasId).?;
        count.* += 1;
        if (count.* == sk.gfx.queryImageNumSlices(atlasImage)) {
            sk.gfx.sealImage(atlasImage);
        }
        return false;
    }
};

pub const Icon = png.Image;
const IconHandler = fn (u64, Icon) void;
pub fn loadIcon(path: Path, handle: u64, handler: IconHandler) void {
    _ = file.load(path, handle, struct {
        fn callback(resp: Response) bool {
            const icon = png.loadIcon(allocator, resp.data) catch |err| {
                std.debug.panic("{s}: {}", .{ resp.path, err });
            };
            defer allocator.free(icon.data);
            handler(resp.index, icon);
            return false;
        }
    }.callback);
}

const view = struct {
    var cache: std.AutoHashMapUnmanaged(Id, sk.gfx.View) = .empty;

    fn handler(resp: Response) bool {
        const img = png.load(allocator, resp.data) catch |err| {
            std.debug.panic("{s}: {}", .{ resp.path, err });
        };
        defer allocator.free(img.data);
        const imageView: sk.gfx.View = .{ .id = @intCast(resp.index) };

        sk.gfx.initView(imageView, .{ .texture = .{
            .image = makeImage(img.width, img.height, 1, img.data),
        } });
        const image = imageCache.getPtr(id(resp.path)).?;
        // 文件尺寸必须与调用方提供的尺寸一致。
        std.debug.assert(image.size.x == @as(f32, @floatFromInt(img.width)));
        std.debug.assert(image.size.y == @as(f32, @floatFromInt(img.height)));
        return false;
    }

    fn makeImage(w: i32, h: i32, layers: i32, data: anytype) sk.gfx.Image {
        return sk.gfx.makeImage(.{
            .width = w,
            .height = h,
            .type = .ARRAY,
            .num_slices = layers,
            .data = init: {
                var imageData = sk.gfx.ImageData{};
                imageData.mip_levels[0] = sk.gfx.asRange(data);
                break :init imageData;
            },
        });
    }
};

const sound = struct {
    var cache: std.AutoHashMapUnmanaged(Id, audio.Sound) = .empty;
    // 音效解码回调串行执行，首次分配后复用工作缓冲区。
    var buffer: ?[]align(8) u8 = null;

    fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| allocator.free(value.samples);
        cache.deinit(allocator);
        if (buffer) |value| allocator.free(value);
    }

    fn load(path: Path, option: audio.Sound.Option) audio.Sound {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = .{ .option = option };
        _ = file.load(path, 0, handler);
        return .{};
    }

    fn handler(resp: Response) bool {
        if (buffer == null) {
            buffer = c.stbAudio.allocBuffer(allocator) catch oom();
        }
        const stbAudio = c.stbAudio.loadFromMemory(resp.data, buffer.?);
        defer stbAudio.unload();

        const channels: u8 = @intCast(stbAudio.getInfo().channels);
        std.debug.assert(channels == 1 or channels == 2);
        const size = stbAudio.getSampleCapacity();
        const samples = allocator.alloc(f32, size) catch oom();
        const decoded = stbAudio.fillSamples(samples, channels);
        // 音效必须至少解码出一帧，避免循环播放时无法推进。
        std.debug.assert(decoded > 0);

        const soundCache = cache.getPtr(id(resp.path)).?;
        const option = soundCache.option;
        soundCache.* = .{ .samples = samples, .channels = channels };
        _ = audio.playSoundOption(resp.path, option);
        return false;
    }
};

const music = struct {
    const Music = struct {
        source: ?*c.stbAudio.Audio,
        // 独立分配，缓存表扩容时工作缓冲区的地址保持不变。
        buffer: []align(8) u8,

        const empty: Music = .{ .source = null, .buffer = &.{} };

        fn deinit(self: *Music) void {
            if (self.source) |source| source.unload();
            allocator.free(self.buffer);
        }
    };
    var cache: std.AutoHashMapUnmanaged(Id, Music) = .empty;

    fn load(path: Path, loop: bool) ?*c.stbAudio.Audio {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) return entry.value_ptr.source;

        entry.value_ptr.* = .empty;
        _ = file.load(path, if (loop) 1 else 0, handler);
        return null;
    }

    fn handler(resp: Response) bool {
        var buffer = c.stbAudio.allocBuffer(allocator) catch oom();
        var stbAudio = c.stbAudio.loadFromMemory(resp.data, buffer);
        const size = stbAudio.getBufferSize();
        if (size < buffer.len and allocator.resize(buffer, size)) {
            // resize 不移动地址且保留全部长期数据，旧解码器只用于关闭。
            stbAudio.unload();
            buffer = buffer[0..size];
            stbAudio = c.stbAudio.loadFromMemory(resp.data, buffer);
        }
        // 音乐必须包含可播放的帧。
        std.debug.assert(stbAudio.getSampleCount() > 0);
        const musicCache = cache.getPtr(id(resp.path)).?;
        musicCache.* = .{ .source = stbAudio, .buffer = buffer };
        audio.playMusicOption(resp.path, resp.index == 1);
        return true;
    }

    pub fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| value.deinit();
        cache.deinit(allocator);
    }
};

pub const Response = struct {
    index: u64 = undefined,
    path: [:0]const u8,
    data: []const u8 = &.{},
};

var fileBuffer: [4][]u8 = @splat(&.{});
pub const file = struct {
    pub const Data = struct { bytes: []const u8, owned: bool = false };

    const FileState = enum { init, loading, loaded, handled };
    const Handler = *const fn (Response) bool;

    const FileCache = struct {
        state: FileState = .init,
        index: u64 = 0,
        data: Data = .{ .bytes = &.{} },
        handler: Handler = undefined,
    };

    var cache: std.AutoHashMapUnmanaged(Id, FileCache) = .empty;
    var mapping: ?std.Io.File.MemoryMap = null; // 原始资源切片的共同所有者。

    // 直接映射当前程序，将包内资源登记为已加载的借用数据。
    fn init() !void {
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
        if (!std.mem.endsWith(u8, bytes, "b0b0")) {
            mapped.destroy(io);
            exe.close(io);
            return;
        }

        initPack(bytes);
        mapping = mapped;
    }

    // 资源模块初始化后调用；切片必须是有效 pack，并保持到资源模块销毁。
    // 只借用包内数据，不复制或释放调用方提供的切片。
    pub fn initPack(bytes: []const u8) void {
        std.debug.assert(std.mem.endsWith(u8, bytes, "b0b0"));
        const footer = bytes[bytes.len - 12 ..];
        const count = memory.readInt(u32, footer[0..4]);
        const size = memory.readInt(u32, footer[4..8]);
        const start = bytes.len - size;
        const indexStart = bytes.len - 12 - count * 12;
        cache.ensureUnusedCapacity(allocator, count) catch oom();
        for (0..count) |i| {
            const entry = bytes[indexStart + i * 12 ..][0..12];
            const hash = memory.readInt(u32, entry[0..4]);
            const offset = start + memory.readInt(u32, entry[4..8]);
            const length = memory.readInt(u32, entry[8..12]);
            cache.putAssumeCapacity(hash, .{
                .state = .loaded,
                .data = .{ .bytes = bytes[offset..][0..length] },
            });
        }
        std.log.info("loaded asset pack: {} files", .{count});
    }

    pub fn put(path: Path, data: Data) void {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = .{ .state = .loaded, .data = data };
    }

    pub fn load(path: Path, index: u64, handler: Handler) *FileCache {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) {
            const value = entry.value_ptr;
            if (value.state == .loaded) {
                value.index = index;
                value.handler = handler;
                handleLoaded(path, value, value.data.bytes.len);
                return value;
            }
            if (value.index != index or value.handler != handler) {
                std.debug.panic("asset path conflict: {s}", .{path});
            }
            return entry.value_ptr;
        }

        entry.value_ptr.* = .{ .index = index, .handler = handler };

        // 缓存和 pack 都未命中时，首次按需启动异步加载器。
        if (!sk.fetch.valid()) {
            sk.fetch.setup(.{
                .num_lanes = fileBuffer.len,
                .logger = .{ .func = sk.log.func },
                .allocator = memory.sokolAllocator(sk.fetch.Allocator),
            });
        }

        var buffer: [1024]u8 = undefined;
        std.debug.assert(buffer.len == sk.fetch.maxPath());
        const fmt = assetRoot ++ "{s}";
        const filePath = memory.formatZ(&buffer, fmt, .{path});
        std.log.info("loading {s}", .{filePath});
        _ = sk.fetch.send(.{ .path = filePath, .callback = callback });

        entry.value_ptr.state = .loading;
        return entry.value_ptr;
    }

    fn callback(responses: [*c]const sk.fetch.Response) callconv(.c) void {
        const resp = responses[0];
        if (resp.failed) {
            const msg = "assets load failed, path: {s}, error code: {}";
            std.debug.panic(msg, .{ resp.path, resp.error_code });
        }
        if (resp.dispatched) {
            std.debug.assert(fileBuffer[resp.lane].len == 0);
            const len = maxFileSize;
            fileBuffer[resp.lane] = allocator.alloc(u8, len) catch oom();
            const buffer = sk.fetch.asRange(fileBuffer[resp.lane]);
            sk.fetch.bindBuffer(resp.handle, buffer);
            return;
        }

        const filePath = std.mem.span(resp.path);
        std.log.info("loaded from: {s}", .{filePath});
        const path = filePath[assetRoot.len..];

        const value = cache.getPtr(id(path)).?;
        value.data = .{ .bytes = fileBuffer[resp.lane], .owned = true };
        value.state = .loaded;
        handleLoaded(path, value, resp.data.size);
        fileBuffer[resp.lane] = &.{};
    }

    // 同步和异步加载共用数据释放逻辑，回调自行决定是否保留原始数据。
    fn handleLoaded(path: Path, value: *FileCache, size: usize) void {
        const response: Response = .{
            .index = value.index,
            .path = path,
            .data = value.data.bytes[0..size],
        };

        const owned = value.data.owned;
        // 回调期间禁止使文件缓存指针失效的操作。
        cache.lockPointers();
        defer cache.unlockPointers();
        if (!value.handler(response)) {
            if (owned) allocator.free(value.data.bytes);
            value.data = .{ .bytes = &.{} };
        } else if (owned and allocator.resize(value.data.bytes, size)) {
            // resize 保证地址不变，音乐可以继续使用加载数据。
            value.data.bytes = value.data.bytes[0..size];
        }
        value.state = .handled;
    }

    pub fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| {
            if (value.data.owned) allocator.free(value.data.bytes);
        }
        cache.deinit(allocator);
        // 所有资源使用者销毁后，再释放它们借用的映射内存。
        if (mapping) |*mapped| {
            const exe = mapped.file;
            mapped.destroy(io);
            exe.close(io);
        }
    }
};

pub const Stats = struct {
    image: usize,
    file: usize,
    sound: usize,
    music: usize,
};

// 查询当前已加载并缓存的资源统计数据
pub fn queryStats() Stats {
    return .{
        .image = imageCache.count(),
        .file = file.cache.count(),
        .sound = sound.cache.count(),
        .music = music.cache.count(),
    };
}
