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

    sampler.init();

    sk.fetch.setup(.{
        .num_lanes = fileBuffer.len,
        .logger = .{ .func = sk.log.func },
        .allocator = @bitCast(memory.skAllocator),
    });
}

pub fn initCaches(allocator_: std.mem.Allocator) void {
    allocator, imageCache = .{ allocator_, .empty };
    atlas.cache = .empty;
    view.cache, file.cache = .{ .empty, .empty };
    sound.cache, music.cache = .{ .empty, .empty };
    gpu.pipelines, gpu.shaders = .{ .empty, .empty };
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

    entry.value_ptr.* = .{
        .view = view.load(path),
        .sampler = smp,
        .size = option.size,
    };
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

    const PageIndex = extern struct { atlasId: Id, layer: i32 };

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

    fn load(path: Path) sk.gfx.View {
        const imageView = sk.gfx.allocView();
        cache.put(allocator, id(path), imageView) catch oom();
        _ = file.load(path, imageView.id, handler);
        return imageView;
    }

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

    fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| allocator.free(value.samples);
        cache.deinit(allocator);
    }

    fn load(path: Path, option: audio.Sound.Option) audio.Sound {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = .{ .option = option };
        _ = file.load(path, 0, handler);
        return entry.value_ptr.*;
    }

    fn handler(resp: Response) bool {
        const stbAudio = c.stbAudio.loadFromMemory(resp.data);
        defer c.stbAudio.unload(stbAudio);
        const info = c.stbAudio.getInfo(stbAudio);

        const channels: i32 = @intCast(info.channels);
        const size = c.stbAudio.getSampleCount(stbAudio) * channels;
        const samples = allocator.alloc(f32, @intCast(size)) catch oom();
        const decoded = c.stbAudio.fillSamples(stbAudio, samples, channels);
        // 音效必须至少解码出一帧，避免循环播放时无法推进。
        std.debug.assert(decoded > 0);

        const soundCache = cache.getPtr(id(resp.path)).?;
        const option = soundCache.option;
        soundCache.* = .{
            .samples = samples,
            .channels = @intCast(channels),
        };
        _ = audio.playSoundOption(resp.path, option);
        return false;
    }
};

const music = struct {
    var cache: std.AutoHashMapUnmanaged(Id, ?*c.stbAudio.Audio) = .empty;

    fn load(path: Path, loop: bool) ?*c.stbAudio.Audio {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = null;
        _ = file.load(path, if (loop) 1 else 0, handler);
        return null;
    }

    fn handler(resp: Response) bool {
        const stbAudio = c.stbAudio.loadFromMemory(resp.data);
        // 音乐必须包含可播放的帧。
        std.debug.assert(c.stbAudio.getSampleCount(stbAudio) > 0);
        cache.getPtr(id(resp.path)).?.* = stbAudio;
        audio.playMusicOption(resp.path, resp.index == 1);
        return true;
    }

    pub fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |v| if (v.*) |s| c.stbAudio.unload(s);
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

        var buffer: [1024]u8 = undefined;
        std.debug.assert(buffer.len == sk.fetch.maxPath());
        const fmt = assetRoot ++ "{s}";
        const filePath = std.fmt.bufPrintZ(&buffer, fmt, .{path}) catch
            @panic("asset path too long");
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

    fn handleLoaded(path: Path, value: *FileCache, size: usize) void {
        const response: Response = .{
            .index = value.index,
            .path = path,
            .data = value.data.bytes[0..size],
        };

        const owned = value.data.owned;
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
