const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");

const zhu = @import("zhu.zig");
const graphics = @import("graphics.zig");
const audio = @import("audio.zig");
const decoder = @import("internal/image.zig");
pub const fetch = @import("internal/fetch.zig");
const core = @import("internal/core.zig");

const oom = core.oom;
const panicFmt = std.debug.panic;
const Image = graphics.Image;
const Vector2 = zhu.Vector2;
const Filter = graphics.Filter;
const Path = [:0]const u8;

var gpa: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
pub var frameStats: FrameStats = .{}; // 本帧绘制统计。
var imageCache: std.AutoHashMapUnmanaged(Id, graphics.Image) = .empty;

// 配置 IO 和统计分配器，不创建图形资源。
pub fn setup(io_: std.Io, gpa_: std.mem.Allocator) std.mem.Allocator {
    io = io_;
    counter = core.Counter.init(gpa_);
    gpa = counter.allocator();
    return gpa;
}

// 在图形环境建立后初始化资源加载和默认采样器。
pub fn init() void {
    fetch.init(io, gpa);
    sampler.init();
}

// 开始本帧绘制，重置统计并清空顶点，保留暂存区容量。
pub fn beginDraw() void {
    frameStats = .{};
    gpu.vertices.clearRetainingCapacity();
}

// 推进异步加载，并在主线程执行资源回调。
pub fn update() void {
    fetch.update();
}

pub fn deinit() void {
    imageCache.deinit(gpa);
    atlas.cache.deinit(gpa);
    view.deinit();
    sound.deinit();
    music.deinit();
    fetch.deinit();
    gpu.deinit();
    sk.gfx.destroySampler(sampler.nearest);
    sk.gfx.destroySampler(sampler.linear);
}

pub const ImageOption = struct { filter: Filter = .nearest };

pub fn loadImage(path: Path, size: Vector2, option: ImageOption) Image {
    const entry = imageCache.getOrPut(gpa, id(path)) catch oom();
    if (entry.found_existing) {
        std.debug.assert(entry.value_ptr.filter == option.filter);
        return entry.value_ptr.*;
    }

    const imageView = sk.gfx.allocView();
    entry.value_ptr.* = .{
        .view = imageView,
        .size = size,
        .filter = option.filter,
    };
    view.put(imageView, .{ .sampler = sampler.get(option.filter) });
    fetch.load(path, imageView.id, view.handler, .{ .kind = .image });
    return entry.value_ptr.*;
}

pub const Id = fetch.Id;
pub const id = fetch.id;

pub fn getImage(imageId: Id) ?graphics.Image {
    if (builtin.is_test) return .empty;
    return imageCache.get(imageId);
}

pub fn getImageByPath(comptime path: Path) ?graphics.Image {
    return getImage(id(path));
}

pub fn putImage(imageId: Id, image: graphics.Image) void {
    imageCache.put(gpa, imageId, image) catch oom();
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
    pub fn get(filter: Filter) sk.gfx.Sampler {
        return switch (filter) {
            .nearest => nearest,
            .linear => linear,
        };
    }
};

pub const gpu = struct {
    // 统一持有缓冲句柄，提前销毁时移除，退出时释放剩余缓冲。
    var buffers: std.AutoHashMapUnmanaged(sk.gfx.Buffer, void) = .empty;
    var vertices: std.ArrayList(graphics.Vertex) = .empty; // 本帧顶点数据。
    var pipelines: std.ArrayListUnmanaged(sk.gfx.Pipeline) = .empty;
    var shaders: std.ArrayListUnmanaged(sk.gfx.Shader) = .empty;
    // 待提交的图像复制记录，源缓冲和目标图像必须保持有效直到提交。
    var updates: std.ArrayList(sk.gfx.CopyBufferToImageDesc) = .empty;

    // 创建由资产模块管理的缓冲。
    pub fn makeBuffer(desc: sk.gfx.BufferDesc) sk.gfx.Buffer {
        const buffer = sk.gfx.makeBuffer(desc);
        buffers.put(gpa, buffer, {}) catch oom();
        return buffer;
    }

    // 提前释放已登记的缓冲，避免退出时重复销毁。
    pub fn destroyBuffer(buffer: sk.gfx.Buffer) void {
        if (buffer.id == 0) return;
        const removed = buffers.remove(buffer);
        std.debug.assert(removed);
        sk.gfx.destroyBuffer(buffer);
    }

    // 追加单个顶点，容量不足时自动增长。
    pub fn addVertex(value: graphics.Vertex) void {
        vertices.append(gpa, value) catch oom();
        frameStats.vertex = vertices.items.len;
    }

    // 追加一组顶点，容量不足时自动增长。
    pub fn addVertices(values: []const graphics.Vertex) void {
        vertices.appendSlice(gpa, values) catch oom();
        frameStats.vertex = vertices.items.len;
    }

    // 在渲染通道开始前提交图片更新并上传顶点。
    // 返回当前有效的缓冲句柄，未扩容时返回原句柄。
    pub fn upload(buffer: sk.gfx.Buffer) sk.gfx.Buffer {
        uploadImageUpdates();

        if (vertices.items.len == 0) return buffer;
        const data = sk.gfx.asRange(vertices.items);
        var result = buffer;
        if (sk.gfx.queryBufferSize(buffer) < data.size) {
            destroyBuffer(buffer);
            result = makeBuffer(.{
                .size = vertices.capacity * @sizeOf(graphics.Vertex),
                .usage = .{ .write_transient = true },
                .label = "batch vertices",
            });
        }
        sk.gfx.writeBufferTransient(.{
            .src = .{ .data = data },
            .dst = .{ .buffer = result },
        });
        return result;
    }

    // 执行排队的纹理复制，完成后源缓冲可交给 Sokol 销毁。
    pub fn uploadImageUpdates() void {
        for (updates.items) |value| sk.gfx.copyBufferToImage(value);
        updates.clearRetainingCapacity();
    }

    // 登记由引擎统一销毁的流水线。
    pub fn addPipeline(value: sk.gfx.Pipeline) void {
        pipelines.append(gpa, value) catch oom();
    }

    // 登记由引擎统一销毁的着色器。
    pub fn addShader(value: sk.gfx.Shader) void {
        shaders.append(gpa, value) catch oom();
    }

    // 登记图像复制操作，上传缓冲的写入策略由调用方决定。
    pub fn addUpdate(value: sk.gfx.CopyBufferToImageDesc) void {
        updates.append(gpa, value) catch oom();
    }

    fn deinit() void {
        updates.deinit(gpa);
        updates = .empty;
        vertices.deinit(gpa);
        vertices = .empty;
        frameStats = .{};
        var iterator = buffers.keyIterator();
        while (iterator.next()) |buffer| sk.gfx.destroyBuffer(buffer.*);
        buffers.deinit(gpa);
        buffers = .empty;

        for (pipelines.items) |value| sk.gfx.destroyPipeline(value);
        pipelines.deinit(gpa);
        pipelines = .empty;

        for (shaders.items) |value| sk.gfx.destroyShader(value);
        shaders.deinit(gpa);
        shaders = .empty;
    }
};

pub const atlas = struct {
    pub const Option = struct { pages: u8 = 0, filter: Filter = .nearest };

    // 记录每个图集剩余待加载的图片页数。
    var cache: std.AutoHashMapUnmanaged(Id, i32) = .empty;

    // 打包为文件加载回调的 64 位标识。
    const PageIndex = packed struct(u64) { atlasId: Id, layer: i32 };

    // 加载图片并预留可写页；返回整页 Image，layer 是首个可写层。
    pub fn load(source: graphics.Atlas, option: Option) Image {
        // 层号使用一个字节，创建 GPU 纹理前检查图集页数。
        std.debug.assert(source.imagePaths.len > 0);
        std.debug.assert(source.imagePaths.len + option.pages <= 256);
        const atlasId = id(source.imagePaths[0]);
        const entry = cache.getOrPut(gpa, atlasId) catch oom();
        if (entry.found_existing) {
            var image = imageCache.get(atlasId).?;
            std.debug.assert(image.filter == option.filter);
            image.layer = if (option.pages == 0) 0 else @intCast(source.imagePaths.len);
            return image;
        }

        const atlasView = sk.gfx.makeView(.{
            .texture = .{ .image = sk.gfx.makeImage(.{
                .usage = .{ .write_unsealed = true, .copy_dst = option.pages > 0 },
                .width = @intFromFloat(source.size.x),
                .height = @intFromFloat(source.size.y),
                .type = .ARRAY,
                .num_slices = @intCast(source.imagePaths.len + option.pages),
            }) },
        });
        view.put(atlasView, .{ .sampler = sampler.get(option.filter) });
        entry.value_ptr.* = @intCast(source.imagePaths.len);

        const len: u32 = @intCast(source.imagePaths.len + source.images.len);
        imageCache.ensureUnusedCapacity(gpa, len) catch oom();
        for (source.imagePaths, 0..) |path, i| {
            imageCache.putAssumeCapacity(id(path), .{
                .view = atlasView,
                .layer = @intCast(i),
                .filter = option.filter,
                .offset = .zero,
                .size = source.size,
            });

            const pageIndex = PageIndex{
                .atlasId = atlasId,
                .layer = @intCast(i),
            };
            fetch.load(path, @bitCast(pageIndex), handler, .{ .kind = .image });
        }

        for (source.images) |image| {
            var img = image;
            img.view = atlasView;
            img.filter = option.filter;
            imageCache.putAssumeCapacity(image.view.id, img);
        }
        return .{
            .view = atlasView,
            .layer = if (option.pages == 0) 0 else @intCast(source.imagePaths.len),
            .size = source.size,
            .filter = option.filter,
        };
    }

    fn handler(index: u64, response: Response) void {
        const pageIndex: PageIndex = @bitCast(index);
        const atlasView = imageCache.get(pageIndex.atlasId).?.view;
        const atlasImage = sk.gfx.queryViewImage(atlasView);
        const width = sk.gfx.queryImageWidth(atlasImage);
        const height = sk.gfx.queryImageHeight(atlasImage);
        std.debug.assert(response.extra1 == width);
        std.debug.assert(response.extra2 == height);

        sk.gfx.writeImageUnsealed(.{
            .src = .{ .data = sk.gfx.asRange(response.data) },
            .dst = .{ .image = atlasImage, .slice = pageIndex.layer },
            // 零值表示从当前图层写到最后一层，这里只写本次加载的图层。
            .size = .{ .num_slices = 1 },
        });

        const count = cache.getPtr(pageIndex.atlasId).?;
        count.* -= 1;
        if (count.* == 0) {
            sk.gfx.sealImage(atlasImage);
        }
    }
};

pub const Icon = decoder.Image;
const IconHandler = fn (u64, Icon) void;
pub fn loadIcon(path: Path, handle: u64, handler: IconHandler) void {
    fetch.load(path, handle, struct {
        fn callback(index: u64, resp: Response) void {
            handler(index, .{
                .width = resp.extra1,
                .height = resp.extra2,
                .data = @constCast(resp.data),
            });
        }
    }.callback, .{ .kind = .image });
}

pub const view = struct {
    // 视图的绘制配置，流水线为空时使用默认图片流水线。
    pub const Info = struct {
        sampler: sk.gfx.Sampler,
        pipeline: ?sk.gfx.Pipeline = null,
    };

    var cache: std.AutoHashMapUnmanaged(graphics.View, Info) = .empty;

    // 创建视图时登记采样器与流水线。
    pub fn put(source: graphics.View, info: Info) void {
        cache.put(gpa, source, info) catch oom();
    }

    // 返回视图配置，视图必须已经登记。
    pub fn get(source: graphics.View) Info {
        return cache.get(source).?;
    }

    // 用于修改已有流水线，缓存扩容或移除记录后指针失效。
    pub fn getPtr(source: graphics.View) *Info {
        return cache.getPtr(source).?;
    }

    // 提前释放采样视图，同时移除记录，退出时不再重复销毁。
    pub fn destroy(source: graphics.View) void {
        _ = cache.remove(source);
        sk.gfx.destroyView(source);
    }

    // 销毁仍在缓存中的采样视图，再释放记录表。
    pub fn deinit() void {
        var iterator = cache.keyIterator();
        while (iterator.next()) |key| sk.gfx.destroyView(key.*);

        cache.deinit(gpa);
        cache = .empty;
    }

    fn handler(index: u64, resp: Response) void {
        const imageView: sk.gfx.View = .{ .id = @intCast(index) };

        sk.gfx.initView(imageView, .{ .texture = .{
            .image = makeImage(resp.extra1, resp.extra2, 1, resp.data),
        } });
        const image = imageCache.getPtr(id(resp.path)).?;
        // 文件尺寸必须与调用方提供的尺寸一致。
        const width: f32 = @floatFromInt(resp.extra1);
        const height: f32 = @floatFromInt(resp.extra2);
        std.debug.assert(image.size.x == width);
        std.debug.assert(image.size.y == height);
    }

    fn makeImage(w: i32, h: i32, layers: i32, data: anytype) sk.gfx.Image {
        return sk.gfx.makeImage(.{
            .width = w,
            .height = h,
            .type = .ARRAY,
            .num_slices = layers,
            .data = sk.gfx.asRange(data),
        });
    }
};

pub const sound = struct {
    pub const Source = audio.SoundSource;
    pub const Handler = fn (Id, Source) void;

    var cache: std.AutoHashMapUnmanaged(Id, ?Source) = .empty;

    fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| {
            if (value.*) |source| source.deinit(gpa);
        }
        cache.deinit(gpa);
    }

    pub fn load(path: Path, handler: Handler) ?Source {
        const assetId = id(path);
        const entry = cache.getOrPut(gpa, assetId) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = null;
        // 缓存命中直接返回资源，首次加载通过回调交付。
        fetch.load(path, assetId, struct {
            fn callback(index: u64, resp: Response) void {
                const source = Source.init(gpa, resp.data) catch |err|
                    panicFmt("sound init failed: {s}: {}", .{ resp.path, err });
                const loadedId: Id = @intCast(index);
                cache.getPtr(loadedId).?.* = source;
                handler(loadedId, source);
            }
        }.callback, .{});
        return cache.get(assetId).?;
    }
};

pub const music = struct {
    pub const Source = audio.MusicSource;
    pub const Handler = fn (Id, Source) void;

    var cache: std.AutoHashMapUnmanaged(Id, ?Source) = .empty;

    pub fn load(path: Path, handler: Handler) ?Source {
        const assetId = id(path);
        const entry = cache.getOrPut(gpa, assetId) catch oom();
        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = null;
        // 缓存命中直接返回资源，首次加载通过回调交付。
        fetch.load(path, assetId, struct {
            fn callback(index: u64, resp: Response) void {
                const rate: u32 = @intCast(sk.audio.sampleRate());
                const source = Source.init(gpa, resp.data, rate) catch |err|
                    panicFmt("music init failed: {s}: {}", .{ resp.path, err });
                const loadedId: Id = @intCast(index);
                cache.getPtr(loadedId).?.* = source;
                handler(loadedId, source);
            }
        }.callback, .{});
        return cache.get(assetId).?;
    }

    pub fn deinit() void {
        var iterator = cache.valueIterator();
        while (iterator.next()) |value| {
            if (value.*) |source| source.deinit(gpa);
        }
        cache.deinit(gpa);
    }
};

pub const Response = fetch.Response;

// 本帧处理的字符数和顶点数。
pub const FrameStats = struct {
    text: usize = 0, // 进入绘制流程的字符数量，不含换行。
    vertex: usize = 0, // 本帧已记录的顶点数量。
};

// 当前资源总量与内存统计；内存峰值从初始化开始累计。
pub const TotalStats = struct {
    image: usize,
    file: usize,
    sound: usize,
    music: usize,
    vertexCapacity: usize, // 当前 CPU 顶点暂存区可容纳的顶点数量。
    memoryUsed: usize, // 当前分配的字节数。
    memoryPeak: usize, // 初始化以来分配字节数的峰值。
};

// 返回统计值副本，各项独立读取，不保证来自同一时刻。
pub fn queryTotalStats() TotalStats {
    return .{
        .image = imageCache.count(),
        .file = fetch.count(),
        .sound = sound.cache.count(),
        .music = music.cache.count(),
        .vertexCapacity = gpu.vertices.capacity,
        .memoryUsed = counter.used.load(.monotonic),
        .memoryPeak = counter.max.load(.monotonic),
    };
}

var counter: core.Counter = undefined;

fn sk_alloc(len: usize, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    return alloc(gpa, len);
}

fn sk_free(ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    free(gpa, ptr);
}

// C 的 free 不传长度，所以在返回指针前面存一份长度。
const cAlign = std.mem.Alignment.of(std.c.max_align_t);
const cHeaderSize = std.mem.alignForward(usize, //
    @sizeOf(usize), @alignOf(std.c.max_align_t));

fn cSlice(ptr: *anyopaque) []align(@alignOf(std.c.max_align_t)) u8 {
    const base = @as([*]u8, @ptrCast(ptr)) - cHeaderSize;
    const header: *usize = @ptrCast(@alignCast(base));
    return @alignCast(base[0 .. cHeaderSize + header.*]);
}

fn alloc(gpa_: std.mem.Allocator, len: usize) ?*anyopaque {
    if (len == 0) return null;
    const base = gpa_.rawAlloc(cHeaderSize + len, //
        cAlign, @returnAddress()) orelse return null;
    @as(*usize, @ptrCast(@alignCast(base))).* = len;
    return @ptrCast(base + cHeaderSize);
}

fn free(gpa_: std.mem.Allocator, ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    gpa_.rawFree(cSlice(p), cAlign, @returnAddress());
}

// Sokol 统一使用资源模块的分配器。
pub fn sokolAllocator(comptime T: type) T {
    return .{ .alloc_fn = sk_alloc, .free_fn = sk_free };
}
