const std = @import("std");

const sk = @import("sokol");
const c = @import("internal/c.zig");
const graphics = @import("graphics.zig");
const audio = @import("audio.zig");
const png = @import("internal/png.zig");
const memory = @import("internal/memory.zig");

const oom = memory.oom;
const Image = graphics.Image;
const Path = [:0]const u8;
const assetRoot = "assets/";

var allocator: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
var imageCache: std.AutoHashMapUnmanaged(Id, graphics.Image) = .empty;
var maxFileSize: usize = 0;

pub fn init(io_: std.Io, gpa: std.mem.Allocator, maxSize: usize) void {
    io = io_;
    memory.init(gpa);
    allocator = memory.allocator.raw;
    maxFileSize = maxSize;

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
}

pub fn deinit() void {
    imageCache.deinit(allocator);
    atlas.deinit();
    view.cache.deinit(allocator);
    sound.cache.deinit(allocator);
    music.deinit();
    file.deinit();
    if (sk.fetch.valid()) sk.fetch.shutdown();
    for (&fileBuffer) |buf| if (buf.len != 0) allocator.free(buf);
}

pub fn loadImage(path: Path, size: graphics.Vector2) Image {
    const entry = imageCache.getOrPut(allocator, id(path)) catch oom();
    if (!entry.found_existing) {
        const imageView = view.load(path);
        entry.value_ptr.* = .{ .view = imageView, .size = size };
    }
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

pub fn loadAtlas(source: graphics.Atlas) void {
    atlas.load(source);
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

const atlas = struct {
    var cache: std.AutoHashMapUnmanaged(Id, Load) = .empty;

    const Load = struct {
        view: sk.gfx.View,
        size: graphics.Vector2,
        layers: usize,
        loaded: usize = 0,
        data: []u8,
    };

    const PageIndex = extern struct { atlasId: Id, layer: u32 };

    fn load(source: graphics.Atlas) void {
        const atlasId = id(source.imagePaths[0]);
        const entry = cache.getOrPut(allocator, atlasId) catch oom();
        if (entry.found_existing) return;

        const len: u32 = @intCast(source.imagePaths.len + source.images.len);
        imageCache.ensureUnusedCapacity(allocator, len) catch oom();

        const atlasView = sk.gfx.allocView();
        const pageCount = source.imagePaths.len;
        const size: usize = @intFromFloat(source.size.x * source.size.y);
        entry.value_ptr.* = .{
            .view = atlasView,
            .size = source.size,
            .layers = pageCount,
            .data = allocator.alloc(u8, size * 4 * pageCount) catch oom(),
        };
        for (source.imagePaths, 0..) |path, i| {
            const pageIndex = PageIndex{
                .atlasId = atlasId,
                .layer = @intCast(i),
            };
            _ = file.load(path, @bitCast(pageIndex), handler);
            imageCache.putAssumeCapacity(id(path), .{
                .view = atlasView,
                .layer = @floatFromInt(i),
                .offset = .zero,
                .size = source.size,
            });
        }

        for (source.images) |image| {
            var img = image;
            img.view = atlasView;
            imageCache.putAssumeCapacity(image.view.id, img);
        }
    }

    fn handler(response: Response) []const u8 {
        const pageIndex: PageIndex = @bitCast(response.index);
        const loadContext = cache.getPtr(pageIndex.atlasId).?;
        const img = png.load(allocator, response.data) catch |err| {
            std.debug.panic("{s}: {}", .{ response.path, err });
        };
        defer allocator.free(img.data);

        const width: i32 = @intFromFloat(loadContext.size.x);
        const height: i32 = @intFromFloat(loadContext.size.y);
        std.debug.assert(img.width == width);
        std.debug.assert(img.height == height);

        const start = img.data.len * pageIndex.layer;
        const end = start + img.data.len;
        @memcpy(loadContext.data[start..end], img.data);
        loadContext.loaded += 1;

        if (loadContext.loaded == loadContext.layers) {
            sk.gfx.initView(loadContext.view, .{ .texture = .{
                .image = view.makeImage(
                    @intFromFloat(loadContext.size.x),
                    @intFromFloat(loadContext.size.y),
                    @intCast(loadContext.layers),
                    loadContext.data,
                ),
            } });
            allocator.free(loadContext.data);
            loadContext.data = &.{};
        }
        return &.{};
    }

    fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |v| allocator.free(v.data);
        cache.deinit(allocator);
    }
};

pub const Icon = png.Image;
const IconHandler = fn (u64, Icon) void;
pub fn loadIcon(path: Path, handle: u64, handler: IconHandler) void {
    _ = file.load(path, handle, struct {
        fn callback(resp: Response) []const u8 {
            const icon = png.loadIcon(allocator, resp.data) catch |err| {
                std.debug.panic("{s}: {}", .{ resp.path, err });
            };
            defer allocator.free(icon.data);
            handler(resp.index, icon);
            return &.{};
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

    fn handler(resp: Response) []const u8 {
        const img = png.load(allocator, resp.data) catch |err| {
            std.debug.panic("{s}: {}", .{ resp.path, err });
        };
        defer allocator.free(img.data);
        const imageView: sk.gfx.View = .{ .id = @intCast(resp.index) };

        sk.gfx.initView(imageView, .{ .texture = .{
            .image = makeImage(img.width, img.height, 1, img.data),
        } });
        if (imageCache.getPtr(id(resp.path))) |image| {
            image.size = .{
                .x = @floatFromInt(img.width),
                .y = @floatFromInt(img.height),
            };
        }
        return &.{};
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

    fn load(path: Path, option: audio.Sound.Option) audio.Sound {
        const entry = cache.getOrPut(allocator, id(path)) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = .{ .option = option };
        _ = file.load(path, 0, handler);
        return entry.value_ptr.*;
    }

    fn handler(resp: Response) []const u8 {
        const stbAudio = c.stbAudio.loadFromMemory(resp.data);
        defer c.stbAudio.unload(stbAudio);
        const info = c.stbAudio.getInfo(stbAudio);

        const channels: i32 = @intCast(info.channels);
        const size = c.stbAudio.getSampleCount(stbAudio) * channels;
        const samples = allocator.alloc(f32, @intCast(size)) catch oom();
        _ = c.stbAudio.fillSamples(stbAudio, samples, channels);

        const soundCache = cache.getPtr(id(resp.path)).?;
        const option = soundCache.option;
        soundCache.* = .{
            .samples = samples,
            .channels = @intCast(channels),
        };
        _ = audio.playSoundOption(resp.path, option);
        return std.mem.sliceAsBytes(samples);
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

    fn handler(resp: Response) []const u8 {
        const data = allocator.dupe(u8, resp.data) catch oom();
        const stbAudio = c.stbAudio.loadFromMemory(data);
        cache.getPtr(id(resp.path)).?.* = stbAudio;
        audio.playMusicOption(resp.path, resp.index == 1);
        return data;
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
    const Handler = *const fn (Response) []const u8;

    const FileCache = struct {
        state: FileState = .init,
        index: u64 = 0,
        data: Data = .{ .bytes = &.{} },
        managed: []const u8 = &.{},
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

        value.managed = value.handler(response);
        value.state = .handled;
        if (value.data.owned) allocator.free(value.data.bytes);
        value.data = .{ .bytes = &.{} };
    }

    pub fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| {
            allocator.free(value.managed);
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
