const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
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
pub var fontStats: FontStats = .{}; // 当前字体和字库统计。
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
    if (options.font != .static) glyph.offset = 0;
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
    if (options.font != .static) glyph.deinit();
    fontStats = .{};
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
        const decoded = response.content.image;
        const pageIndex: PageIndex = @bitCast(index);
        const atlasView = imageCache.get(pageIndex.atlasId).?.view;
        const atlasImage = sk.gfx.queryViewImage(atlasView);
        const width = sk.gfx.queryImageWidth(atlasImage);
        const height = sk.gfx.queryImageHeight(atlasImage);
        std.debug.assert(decoded.width == width);
        std.debug.assert(decoded.height == height);

        sk.gfx.writeImageUnsealed(.{
            .src = .{ .data = sk.gfx.asRange(decoded.data) },
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
            handler(index, resp.content.image);
        }
    }.callback, .{ .kind = .image });
}

const ZlibHandler = fn (u64, []const u8) void;

/// 异步加载并解压 zlib；字节仅在回调期间有效，需要保留时自行复制。
pub fn loadZlib(path: Path, handle: u64, handler: ZlibHandler) void {
    fetch.load(path, handle, struct {
        fn callback(index: u64, resp: Response) void {
            handler(index, resp.content.zlib);
        }
    }.callback, .{ .kind = .zlib });
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
        const decoded = resp.content.image;
        const imageView: sk.gfx.View = .{ .id = @intCast(index) };

        sk.gfx.initView(imageView, .{ .texture = .{
            .image = makeImage(decoded.width, decoded.height, 1, decoded.data),
        } });
        const image = imageCache.getPtr(id(resp.path)).?;
        // 文件尺寸必须与调用方提供的尺寸一致。
        const width: f32 = @floatFromInt(decoded.width);
        const height: f32 = @floatFromInt(decoded.height);
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
                const source = resp.content.sound;
                const loadedId: Id = @intCast(index);
                cache.getPtr(loadedId).?.* = source;
                handler(loadedId, source);
            }
        }.callback, .{ .kind = .sound });
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
                const bytes = resp.content.bytes;
                const source = Source.init(gpa, bytes, rate) catch |err|
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

// 字体初始化或缓存变化时更新，读取统计不触发字形查询。
pub const FontStats = struct {
    name: []const u8 = "",
    size: f32 = 0,
    count: usize = 0,
    capacity: usize = 0,
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

// 动态字体的基准度量、字形缓存与图集上传。
pub const glyph = if (options.font == .static) struct {} else struct {
    pub var size: f32 = 18; // 字形度量对应的逻辑基准字号。
    pub var lineHeight: f32 = 18; // 默认逻辑行高为一个基准字号。
    pub const CreateGlyph = *const fn (u32, *Buffer) graphics.Glyph;
    // 来源填写 image.size 的像素尺寸及逻辑度量，图集区域由缓存补全。
    pub var createGlyph: CreateGlyph = undefined;

    var atlasImage: Image = .empty;
    var cache: std.AutoHashMapUnmanaged(u32, graphics.Glyph) = .empty;
    var upload: sk.gfx.Buffer = .{};
    var buffer: Buffer = .{};
    var offset: usize = 0;
    var layer: i32 = 0;
    var x: i32 = 1;
    var y: i32 = 1;
    var rowHeight: i32 = 0;

    // 像素缓冲由资产模块持有，来源可以按实际字形尺寸扩容并填充。
    pub const Buffer = struct {
        data: []u8 = &.{},
        pub fn resize(self: *Buffer, len: usize) []u8 {
            if (self.data.len >= len) return self.data[0..len];
            self.data = gpa.realloc(self.data, len) catch oom();
            return self.data;
        }
    };

    // 绑定图集并初始化字形缓存。
    pub fn init(atlas_: Image, fontSize: f32, source: CreateGlyph) void {
        atlasImage = atlas_;
        createGlyph = source;
        size, lineHeight = .{ fontSize, fontSize };
        fontStats = .{ .size = fontSize };
        const cell: usize = @intFromFloat(@ceil(fontSize) + 2);
        resize(cell);
    }

    // 字号变化时重置装箱和缓存，保留图集及已使用的上传区域。
    pub fn resize(cell: usize) void {
        if (cell > 0) _ = buffer.resize(cell * cell * 4);
        layer = atlasImage.layer;
        x, y, rowHeight = .{ 1, 1, 0 };
        cache.clearRetainingCapacity();
        fontStats.count = 0;
        fontStats.capacity = estimateGlyphCount(cell);
    }

    fn deinit() void {
        gpu.destroyBuffer(upload);
        upload, offset = .{ .{}, 0 };
        gpa.free(buffer.data);
        buffer = .{};
        cache.deinit(gpa);
        cache, atlasImage = .{ .empty, .empty };
        size, lineHeight = .{ 18, 18 };
    }

    // 按字号加两像素边框估算方格容量，只在缓存重建时计算。
    fn estimateGlyphCount(cell: usize) usize {
        if (!atlasImage.isValid() or cell == 0) return 0;
        const texture = sk.gfx.queryViewImage(atlasImage.view);
        const width: usize = @intCast(sk.gfx.queryImageWidth(texture));
        const height: usize = @intCast(sk.gfx.queryImageHeight(texture));
        const layers = sk.gfx.queryImageNumSlices(texture);
        const slices: usize = @intCast(layers - atlasImage.layer);
        return (width / cell) * (height / cell) * slices;
    }

    pub fn findGlyph(code: u32) graphics.Glyph {
        if (cache.get(code)) |item| return item;
        // 图集尚未就绪时返回空字形，不生成像素，也不写入缓存。
        const texture = sk.gfx.queryViewImage(atlasImage.view);
        if (sk.gfx.queryImageState(texture) != .VALID) {
            return .{ .image = .{}, .rect = .init(.zero, .zero), .advance = 0 };
        }
        var item = createGlyph(code, &buffer);
        item.image = packImage(buffer.data, item.image.size);
        cache.put(gpa, code, item) catch oom();
        fontStats.count = cache.count();
        return item;
    }

    // 每个字形包含一像素透明边框，当前层装满后使用下一层。
    fn packImage(pixels: []const u8, imageSize: Vector2) Image {
        // 空字形只参与排版，不占用图集和上传缓冲。
        if (imageSize.x == 0 or imageSize.y == 0) return .empty;
        std.debug.assert(atlasImage.isValid());

        const width: i32 = @intFromFloat(imageSize.x);
        const height: i32 = @intFromFloat(imageSize.y);
        const texture = sk.gfx.queryViewImage(atlasImage.view);
        const atlasWidth = sk.gfx.queryImageWidth(texture);
        const atlasHeight = sk.gfx.queryImageHeight(texture);
        if (x + width + 1 > atlasWidth) {
            x = 1;
            y += rowHeight + 2;
            rowHeight = 0;
        }
        if (y + height + 1 > atlasHeight) {
            if (layer + 1 == sk.gfx.queryImageNumSlices(texture))
                @panic("font atlas layer limit exceeded");
            layer += 1;
            x, y = .{ 1, 1 };
            rowHeight = 0;
        }

        const image = Image{
            .view = atlasImage.view,
            .layer = @intCast(layer),
            .filter = atlasImage.filter,
            .offset = .xy(@floatFromInt(x), @floatFromInt(y)),
            .size = imageSize,
        };

        // 每个字形使用独立的上传区域，复制记录由 GPU 模块统一提交。
        const left, const top = .{ x - 1, y - 1 };
        const copyWidth, const copyHeight = .{ width + 2, height + 2 };
        const len: usize = @intCast(copyWidth * copyHeight * 4);
        std.debug.assert(pixels.len >= len);
        const cap = sk.gfx.queryBufferSize(upload);
        if (offset + len > cap) {
            // 先消费旧缓冲的复制记录，不搬迁已上传的字形数据。
            gpu.uploadImageUpdates();
            gpu.destroyBuffer(upload);
            upload = gpu.makeBuffer(.{
                .size = @max(@max(cap * 2, len), 64 * 1024),
                .usage = .{
                    .staging_buffer = true,
                    .write_transient = true,
                    .copy_src = true,
                },
                .label = "glyph upload",
            });
            offset = 0;
        }
        sk.gfx.writeBufferTransient(.{
            .src = .{ .data = sk.gfx.asRange(pixels[0..len]) },
            .dst = .{ .buffer = upload, .offset = offset },
        });
        gpu.addUpdate(.{
            .src = .{
                .buffer = upload,
                .offset = offset,
                .bytes_per_row = copyWidth * 4,
                .bytes_per_slice = @intCast(len),
            },
            .dst = .{ .image = texture, .x = left, .y = top, .slice = layer },
            .size = .{ .width = copyWidth, .height = copyHeight, .num_slices = 1 },
        });
        offset += len;
        x += copyWidth;
        rowHeight = @max(rowHeight, height);
        return image;
    }
};

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
