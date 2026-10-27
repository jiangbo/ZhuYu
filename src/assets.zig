const std = @import("std");

const sk = @import("sokol");
const graphics = @import("graphics.zig");
const audio = @import("audio.zig");
const png = @import("internal/png.zig");
const memory = @import("internal/memory.zig");
const fetch = @import("internal/fetch.zig");
const options = @import("options");

const oom = memory.oom;
const Image = graphics.Image;
const Vector2 = graphics.Vector2;
const Filter = graphics.Filter;
const Path = [:0]const u8;

var allocator: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
var imageCache: std.AutoHashMapUnmanaged(Id, graphics.Image) = .empty;

pub fn init(io_: std.Io, maxSize: usize) void {
    io = io_;
    allocator = memory.allocator.raw;
    // 开启 append 时只读取程序尾部的资源包，否则启动外部资源加载器。
    if (options.append) {
        file.init() catch |err| {
            std.debug.panic("asset pack init failed: {}", .{err});
        };
    } else {
        fetch.setup(io, allocator, maxSize);
    }

    sampler.init();
}

// 推进异步加载，并在主线程执行资源回调。
pub fn update() void {
    if (!options.append) fetch.dowork();
}

pub fn deinit() void {
    imageCache.deinit(allocator);
    atlas.cache.deinit(allocator);
    view.deinit();
    sound.deinit();
    music.deinit();
    if (!options.append) fetch.shutdown();
    file.deinit();
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
        const current = view.get(entry.value_ptr.view).sampler;
        std.debug.assert(current.id == smp.id);
        return entry.value_ptr.*;
    }

    const imageView = sk.gfx.allocView();
    entry.value_ptr.* = .{
        .view = imageView,
        .size = option.size,
    };
    view.put(imageView, .{ .sampler = smp });
    _ = file.load(path, imageView.id, view.handler);
    return entry.value_ptr.*;
}

pub fn loadSound(path: Path, o: audio.Sound.Option) audio.Sound {
    return sound.load(path, o);
}

pub fn loadMusic(path: Path, loop: bool) ?audio.MusicSource {
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
            const image = imageCache.get(atlasId).?;
            const current = view.get(image.view).sampler;
            std.debug.assert(current.id == smp.id);
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
        view.put(atlasView, .{ .sampler = smp });
        entry.value_ptr.* = 0;

        const len: u32 = @intCast(source.imagePaths.len + source.images.len);
        imageCache.ensureUnusedCapacity(allocator, len) catch oom();
        for (source.imagePaths, 0..) |path, i| {
            imageCache.putAssumeCapacity(id(path), .{
                .view = atlasView,
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
            imageCache.putAssumeCapacity(image.view.id, img);
        }
    }

    fn handler(response: Response) void {
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
    }
};

pub const Icon = png.Image;
const IconHandler = fn (u64, Icon) void;
pub fn loadIcon(path: Path, handle: u64, handler: IconHandler) void {
    _ = file.load(path, handle, struct {
        fn callback(resp: Response) void {
            const icon = png.loadIcon(allocator, resp.data) catch |err| {
                std.debug.panic("{s}: {}", .{ resp.path, err });
            };
            defer allocator.free(icon.data);
            handler(resp.index, icon);
        }
    }.callback);
}

pub const view = struct {
    // 每个采样视图共用的绘制配置，流水线为空时使用默认流水线。
    pub const Info = struct {
        sampler: sk.gfx.Sampler,
        pipeline: ?sk.gfx.Pipeline = null,
    };

    var cache: std.AutoHashMapUnmanaged(graphics.View, Info) = .empty;

    // 创建视图后登记，初始化字体时也可更新已有配置。
    pub fn put(source: graphics.View, value: Info) void {
        cache.put(allocator, source, value) catch oom();
    }

    // 返回配置副本，绘制时仅按视图句柄查找。
    pub fn get(source: graphics.View) Info {
        return cache.get(source).?;
    }

    // 提前释放采样视图，同时移除记录，退出时不再重复销毁。
    pub fn destroy(source: graphics.View) void {
        _ = cache.remove(source);
        sk.gfx.destroyView(source);
    }

    // 销毁仍在缓存中的采样视图，再释放配置表。
    pub fn deinit() void {
        var iterator = cache.keyIterator();
        while (iterator.next()) |key| sk.gfx.destroyView(key.*);

        cache.deinit(allocator);
        cache = .empty;
    }

    fn handler(resp: Response) void {
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

    fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| value.deinit(allocator);
        cache.deinit(allocator);
    }

    fn load(path: Path, option: audio.Sound.Option) audio.Sound {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        // 加载期间再次收到的同音效播放请求不排队、不补播。
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = .{ .option = option };
        // 同步回调只解码，由当前调用负责播放并返回槽位。
        const request = file.load(path, 1, handler);
        // 返回后若尚未加载，异步回调只补播首次请求。
        request.index = 0;
        return entry.value_ptr.*;
    }

    fn handler(resp: Response) void {
        const decoded = audio.Sound.init(allocator, resp.data) catch |err|
            std.debug.panic("sound load failed: {s}: {}", .{ resp.path, err });

        const soundCache = cache.getPtr(id(resp.path)).?;
        const option = soundCache.option;
        soundCache.* = decoded;
        if (resp.index == 0) _ = audio.playSoundOption(resp.path, option);
    }
};

const music = struct {
    var cache: std.AutoHashMapUnmanaged(Id, ?audio.MusicSource) = .empty;

    fn load(path: Path, loop: bool) ?audio.MusicSource {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = null;
        _ = file.load(path, if (loop) 1 else 0, handler);
        return null;
    }

    fn handler(resp: Response) void {
        const rate: u32 = @intCast(sk.audio.sampleRate());
        const source = audio.MusicSource.init(allocator, resp.data, rate) catch |err|
            std.debug.panic("music load failed: {s}: {}", .{ resp.path, err });
        cache.getPtr(id(resp.path)).?.* = source;
        audio.playMusicOption(resp.path, resp.index == 1);
    }

    pub fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| {
            if (value.*) |source| source.deinit(allocator);
        }
        cache.deinit(allocator);
    }
};

pub const Response = struct {
    index: u64 = undefined,
    path: [:0]const u8,
    data: []const u8 = &.{},
};

pub const file = struct {
    pub const Data = struct { bytes: []const u8, owned: bool = false };

    const FileState = enum { init, loading, loaded, handled };
    const Handler = *const fn (Response) void;

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
        if (!std.mem.endsWith(u8, bytes, "b0b0")) return error.AssetPackNotFound;

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

        // append 模式缺少资源时立即报错，不再读取外部文件。
        if (options.append) {
            std.debug.panic("asset not found in appended pack: {s}", .{path});
        }

        entry.value_ptr.* = .{ .index = index, .handler = handler };

        std.log.info("loading {s}", .{path});
        fetch.send(path, callback);

        entry.value_ptr.state = .loading;
        return entry.value_ptr;
    }

    // 缓冲区在主线程移交给缓存，后续沿用资源自身的释放流程。
    fn callback(resp: fetch.Response) void {
        const data = resp.result catch |err| {
            const msg = "assets load failed, path: {s}, error: {}";
            std.debug.panic(msg, .{ resp.path, err });
        };
        const path = resp.path;
        std.log.info("loaded: {s}", .{path});

        const value = cache.getPtr(id(path)).?;
        value.data = .{ .bytes = resp.buffer, .owned = true };
        value.state = .loaded;
        handleLoaded(path, value, data.len);
    }

    // 原始数据仅在回调期间有效，回调结束后释放自有缓冲区并清空引用。
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
        value.handler(response);
        if (owned) allocator.free(value.data.bytes);
        value.data = .{ .bytes = &.{} };
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
