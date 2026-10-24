//! 图集合并。
const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;

const zigimg = @import("zigimg");

// 输入目录用于计算图片 ID，生成的图片资源与源目录分开。
pub const Options = struct {
    input: []const u8,
    images: []const u8 = "atlas", // 相对于 assets 的专用输出目录，生成前清空。
    output: []const u8 = "src/zon/atlas.zon",
    maxSize: u32 = 1024,
    mergeFont: bool = false, // 是否将字体图片路径加入图集。
    font: []const u8 = "src/zon/font.zon", // 开启合入前先生成字体描述。
    name: []const u8 = "atlas", // 同一项目可注册多组资源转换。
};

// 只在注册图集步骤时请求 zigimg，游戏模块不引入图片编码器。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) void {
    const zigimgDep = dep.builder.lazyDependency("zigimg", .{
        .target = b.graph.host,
        .optimize = .safe,
    }) orelse return;
    const config = b.addOptions();
    const input = b.root.joinString(b.allocator, options.input) catch
        @panic("out of memory");
    config.addOption([]const u8, "input", input);
    config.addOption([]const u8, "images", options.images);
    config.addOption([]const u8, "output", options.output);
    config.addOption(u32, "max_size", options.maxSize);
    config.addOption(bool, "merge_font", options.mergeFont);
    config.addOption([]const u8, "font", options.font);
    const tool = b.addExecutable(.{
        .name = "zhuyu-atlas",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/atlas.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    tool.root_module.addOptions("options", config);
    tool.root_module.addImport("zigimg", zigimgDep.module("zigimg"));
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    // 每次显式生成时重新扫描目录，包含新增和删除的 PNG。
    run.has_side_effects = true;
    b.step(options.name, "Generate image atlas").dependOn(&run.step);
}

const Vec2 = struct { x: i32, y: i32 };
const View = struct { id: u32 };
const Image = struct {
    view: View,
    layer: u32,
    offset: Vec2,
    size: Vec2,
};
const Atlas = struct {
    imagePaths: []const []const u8,
    size: Vec2,
    images: []const Image,
};

// 只读取字体图片及尺寸，字形数据仍由字体描述管理。
const Font = struct {
    imageSize: struct { x: f32, y: f32 },
    images: []const []const u8,
};

const Source = struct {
    path: []const u8,
    id: u32,
    width: u32,
    height: u32,
    pixels: []const u8,
};

const Scan = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inputPath: []const u8,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    ids: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
};

// 构建配置直接传入目录与输出位置，不经过工具命令行。
pub fn main(init: std.process.Init) !void {
    const config = @import("options");
    try buildAtlas(init.io, init.arena.allocator(), .{
        .input = config.input,
        .images = config.images,
        .output = config.output,
        .maxSize = config.max_size,
        .mergeFont = config.merge_font,
        .font = config.font,
    });
}

// 扫描源目录、装箱并生成引擎图集描述。
fn buildAtlas(io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    var input = try cwd.openDir(io, options.input, .{ .iterate = true });
    defer input.close(io);
    const outputPath = try std.fs.path.join(allocator, &.{ "assets", options.images });
    if (std.fs.path.dirname(options.output)) |dir| {
        try cwd.createDirPath(io, dir);
    }
    var scan = Scan{
        .io = io,
        .allocator = allocator,
        .inputPath = options.input,
    };
    try scanDir(&scan, input, "");
    if (scan.sources.items.len == 0) return error.NoPngFiles;

    const items = try allocator.alloc(PackItem, scan.sources.items.len);
    for (items, scan.sources.items) |*item, source| item.* = .{
        .path = source.path,
        .width = source.width,
        .height = source.height,
    };

    const layout = try pack(allocator, items, options.maxSize);
    defer layout.deinit(allocator);
    try writeAtlas(io, allocator, .{
        .directory = outputPath,
        .options = options,
        .sources = scan.sources.items,
        .layout = layout,
    });

    std.log.info("packed {} images into {} page(s), size={}x{}", .{
        scan.sources.items.len,
        layout.pageCount,
        layout.width,
        layout.height,
    });
}

fn scanDir(scan: *Scan, dir: std.Io.Dir, relative: []const u8) !void {
    var iterator = dir.iterate();
    while (try iterator.next(scan.io)) |entry| {
        if (entry.kind == .directory) {
            const childRelative = try joinRelative(
                scan.allocator,
                relative,
                entry.name,
            );
            var child = try dir.openDir(scan.io, entry.name, .{
                .iterate = true,
            });
            defer child.close(scan.io);
            try scanDir(scan, child, childRelative);
            continue;
        }
        if (entry.kind != .file or !isPng(entry.name)) continue;

        const path = try joinRelative(scan.allocator, relative, entry.name);
        const filePath = try std.fs.path.join(
            scan.allocator,
            &.{ scan.inputPath, path },
        );
        const decoded = try decodePng(scan.io, scan.allocator, filePath);
        const id = std.hash.Fnv1a_32.hash(path);
        const result = try scan.ids.getOrPut(scan.allocator, id);
        if (result.found_existing) {
            std.debug.panic(
                "image id conflict: {s}, {s}, {}",
                .{ result.value_ptr.*, path, id },
            );
        }
        result.value_ptr.* = path;
        try scan.sources.append(scan.allocator, .{
            .path = path,
            .id = id,
            .width = decoded.width,
            .height = decoded.height,
            .pixels = decoded.pixels,
        });
    }
}

fn joinRelative(
    allocator: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
) ![]const u8 {
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn isPng(name: []const u8) bool {
    const extension = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(extension, ".png");
}

// 两种输出共用本次装箱结果。
const AtlasOutput = struct {
    directory: []const u8,
    options: Options,
    sources: []const Source,
    layout: Layout,
};

// 图集图片使用内容哈希命名，全部写入后再写 ZON 描述。
fn writeAtlas(io: std.Io, allocator: std.mem.Allocator, output: AtlasOutput) !void {
    const sources = output.sources;
    const layout = output.layout;
    const cwd = std.Io.Dir.cwd();
    var fontImages: []const []const u8 = &.{};
    if (output.options.mergeFont) {
        const path = output.options.font;
        const source = try cwd.readFileAllocOptions(
            io,
            path,
            allocator,
            .unlimited,
            .of(u8),
            0,
        );
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const font = std.zon.parse.fromSlice(Font, .{
            .gpa = allocator,
            .arena = allocator,
            .source = source,
            .diagnostics = &diagnostics,
            .ignore_unknown_fields = true,
        }) catch |err| {
            if (err == error.ParseZon) diagnostics.log(path);
            return err;
        };
        // 字体图片直接作为数组层，必须与装箱后的实际页尺寸相同。
        const size = font.imageSize;
        if (size.x != @as(f32, @floatFromInt(layout.width)) or
            size.y != @as(f32, @floatFromInt(layout.height)))
        {
            std.log.err("font {s}: size {d}x{d}, atlas size {}x{}", .{
                path, size.x, size.y, layout.width, layout.height,
            });
            return error.FontSizeMismatch;
        }
        fontImages = font.images;
    }
    // 图集输出目录由生成工具独占，整目录重建以移除旧页面。
    try cwd.deleteTree(io, output.directory);
    try cwd.createDirPath(io, output.directory);
    const pixelCount = std.math.mul(
        usize,
        layout.width,
        layout.height,
    ) catch return error.ImageTooLarge;
    const byteCount = std.math.mul(usize, pixelCount, 4) catch
        return error.ImageTooLarge;

    const pages = try allocator.alloc([]u8, layout.pageCount);
    for (pages) |*page| {
        page.* = try allocator.alloc(u8, byteCount);
        @memset(page.*, 0);
    }

    for (sources, layout.placements) |source, placement| {
        copyExtruded(.{
            .pixels = pages[placement.page],
            .width = layout.width,
        }, source, placement);
    }

    // 纹理数组的总页数包含字体图片。
    const pageCount = layout.pageCount + fontImages.len;
    const imagePaths = try allocator.alloc([]const u8, pageCount);
    for (pages, 0..) |page, index| {
        const bytes = try encodePng(allocator, .{
            .pixels = page,
            .width = layout.width,
            .height = layout.height,
        });
        // 最终文件内容相同时保持名称不变。
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hash = std.fmt.bytesToHex(digest[0..8].*, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            "atlas{}.{s}.png",
            .{ index, hash },
        );
        const path = try std.fs.path.join(
            allocator,
            &.{ output.directory, name },
        );
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
        const resource = try std.fs.path.join(
            allocator,
            &.{ output.options.images, name },
        );
        std.mem.replaceScalar(u8, resource, '\\', '/');
        imagePaths[index] = resource;
    }
    // 仅追加原字体图片路径，保持字体页顺序，不修改图片及字形坐标。
    @memcpy(imagePaths[layout.pageCount..], fontImages);
    const images = try allocator.alloc(Image, sources.len);
    for (images, sources, layout.placements) |*image, source, placement| {
        image.* = .{
            .view = .{ .id = source.id },
            .layer = placement.page,
            .offset = .{
                .x = @intCast(placement.x + 1),
                .y = @intCast(placement.y + 1),
            },
            .size = .{
                .x = @intCast(source.width),
                .y = @intCast(source.height),
            },
        };
    }
    std.mem.sortUnstable(Image, images, {}, struct {
        fn lessThan(_: void, a: Image, b: Image) bool {
            return a.view.id < b.view.id;
        }
    }.lessThan);

    const atlas = Atlas{
        .imagePaths = imagePaths,
        .size = .{
            .x = @intCast(layout.width),
            .y = @intCast(layout.height),
        },
        .images = images,
    };
    const file = try std.Io.Dir.cwd().createFile(io, output.options.output, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.zon.stringify.serialize(atlas, .{}, &writer.interface);
    try writer.interface.flush();
}

// 将图片边缘复制到页内的一像素留白。
const Page = struct { pixels: []u8, width: u32 };

fn copyExtruded(page: Page, source: Source, placement: Placement) void {
    // 把源图边缘向外复制一像素，避免线性采样混入透明颜色。
    const width: usize = source.width;
    const height: usize = source.height;
    for (0..height + 2) |dy| {
        const sourceY = if (dy == 0)
            0
        else
            @min(dy - 1, height - 1);
        const sourceStart = sourceY * width * 4;
        const destinationY = @as(usize, placement.y) + dy;
        const destinationX: usize = placement.x;
        const destinationStart = (destinationY * page.width + destinationX) * 4;
        const row = page.pixels[destinationStart..][0 .. (width + 2) * 4];
        @memcpy(row[0..4], source.pixels[sourceStart..][0..4]);
        @memcpy(
            row[4 .. 4 + width * 4],
            source.pixels[sourceStart..][0 .. width * 4],
        );
        const sourceEnd = sourceStart + (width - 1) * 4;
        @memcpy(row[4 + width * 4 ..][0..4], source.pixels[sourceEnd..][0..4]);
    }
}

const PngImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

// 读取 PNG 并转换为统一的 RGBA 像素。
fn decodePng(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !PngImage {
    var buffer: [64 * 1024]u8 = undefined;
    var image = try zigimg.Image.Managed.fromFilePath(
        allocator,
        io,
        path,
        &buffer,
    );
    defer image.deinit();
    try image.convert(.rgba32);

    return .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .pixels = try allocator.dupe(u8, image.rawBytes()),
    };
}

// 将 RGBA 像素编码为 PNG，尺寸和像素共用一个图片描述。
fn encodePng(allocator: std.mem.Allocator, source: PngImage) ![]u8 {
    const pixels = source.pixels;
    const width = source.width;
    const height = source.height;
    if (pixels.len != @as(usize, width) * height * 4) {
        return error.InvalidPixels;
    }

    const storage = try zigimg.color.PixelStorage.initRawPixels(
        pixels,
        .rgba32,
    );
    const image = zigimg.Image{
        .width = width,
        .height = height,
        .pixels = storage,
    };
    const buffer = try allocator.alloc(u8, pixels.len * 2 + 1024);
    defer allocator.free(buffer);
    const encoded = try image.writeToMemory(
        allocator,
        buffer,
        .{ .png = .{
            .filter_choice = .{ .specified = .none },
        } },
    );
    return allocator.dupe(u8, encoded);
}

// 装箱只需要图片路径与尺寸，路径用于固定排序结果。
const PackItem = struct {
    path: []const u8,
    width: u32,
    height: u32,
};

const Placement = struct {
    page: u32,
    x: u32,
    y: u32,
};

// 每张图片的位置及所有图集页共用的尺寸。
const Layout = struct {
    placements: []Placement,
    pageCount: u32,
    width: u32,
    height: u32,

    fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.placements);
    }
};

const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    fn right(self: Rect) u32 {
        return self.x + self.width;
    }

    fn bottom(self: Rect) u32 {
        return self.y + self.height;
    }

    fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.right() and self.right() > other.x and
            self.y < other.bottom() and self.bottom() > other.y;
    }

    fn contains(self: Rect, other: Rect) bool {
        return other.x >= self.x and other.y >= self.y and
            other.right() <= self.right() and
            other.bottom() <= self.bottom();
    }
};

// 装箱过程中维护每页尚可使用的矩形区域。
const PackPage = struct {
    free: std.ArrayListUnmanaged(Rect) = .empty,
    width: u32 = 0,
    height: u32 = 0,

    fn deinit(self: *PackPage, allocator: std.mem.Allocator) void {
        self.free.deinit(allocator);
    }
};

const Sort = enum { edge, area };
const Fit = enum { short, area };
const Strategy = struct { sort: Sort, fit: Fit };

const Candidate = struct {
    page: usize,
    x: u32,
    y: u32,
    score1: u64,
    score2: u64,

    fn betterThan(self: Candidate, other: Candidate) bool {
        if (self.score1 != other.score1) return self.score1 < other.score1;
        if (self.score2 != other.score2) return self.score2 < other.score2;
        if (self.page != other.page) return self.page < other.page;
        if (self.y != other.y) return self.y < other.y;
        return self.x < other.x;
    }
};

// 尝试四种排序和放置策略，优先选择页数少、总面积小的结果。
fn pack(
    allocator: std.mem.Allocator,
    items: []const PackItem,
    maxSize: u32,
) !Layout {
    if (items.len == 0) return error.EmptyInput;
    if (maxSize < 3) return error.InvalidMaxSize;

    const strategies = [_]Strategy{
        .{ .sort = .edge, .fit = .short },
        .{ .sort = .area, .fit = .short },
        .{ .sort = .edge, .fit = .area },
        .{ .sort = .area, .fit = .area },
    };

    var best: ?Layout = null;
    errdefer if (best) |result| result.deinit(allocator);

    for (strategies) |strategy| {
        const result = try packWith(allocator, items, maxSize, strategy);
        if (best) |current| {
            if (isBetter(result, current)) {
                current.deinit(allocator);
                best = result;
            } else {
                result.deinit(allocator);
            }
        } else {
            best = result;
        }
    }
    return best.?;
}

// 先比较页数，页数相同时比较全部页面的总面积。
fn isBetter(a: Layout, b: Layout) bool {
    if (a.pageCount != b.pageCount) return a.pageCount < b.pageCount;
    const areaA = @as(u64, a.pageCount) * a.width * a.height;
    const areaB = @as(u64, b.pageCount) * b.width * b.height;
    return areaA < areaB;
}

// 按指定策略装箱，每张图片四周预留一像素。
fn packWith(
    allocator: std.mem.Allocator,
    items: []const PackItem,
    maxSize: u32,
    strategy: Strategy,
) !Layout {
    const order = try allocator.alloc(usize, items.len);
    defer allocator.free(order);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sortUnstable(usize, order, SortContext{
        .items = items,
        .sort = strategy.sort,
    }, sortItems);

    const placements = try allocator.alloc(Placement, items.len);
    errdefer allocator.free(placements);

    var pages: std.ArrayListUnmanaged(PackPage) = .empty;
    defer {
        for (pages.items) |*page| page.deinit(allocator);
        pages.deinit(allocator);
    }

    for (order) |itemIndex| {
        const item = items[itemIndex];
        const width = std.math.add(u32, item.width, 2) catch
            return error.ImageTooLarge;
        const height = std.math.add(u32, item.height, 2) catch
            return error.ImageTooLarge;
        if (width > maxSize or height > maxSize) return error.ImageTooLarge;

        var candidate = findCandidate(pages.items, width, height, strategy.fit);
        if (candidate == null) {
            for (pages.items, 0..) |*page, pageIndex| {
                if (!try grow(allocator, page, width, height, maxSize)) {
                    continue;
                }
                candidate = findCandidate(
                    pages.items[pageIndex .. pageIndex + 1],
                    width,
                    height,
                    strategy.fit,
                );
                candidate.?.page = pageIndex;
                break;
            }
        }
        if (candidate == null) {
            try pages.append(allocator, .{});
            const page = &pages.items[pages.items.len - 1];
            std.debug.assert(
                try grow(allocator, page, width, height, maxSize),
            );
            candidate = findCandidate(
                pages.items[pages.items.len - 1 ..],
                width,
                height,
                strategy.fit,
            );
            candidate.?.page = pages.items.len - 1;
        }

        const found = candidate.?;
        const used = Rect{
            .x = found.x,
            .y = found.y,
            .width = width,
            .height = height,
        };
        try place(allocator, &pages.items[found.page], used);
        placements[itemIndex] = .{
            .page = @intCast(found.page),
            .x = found.x,
            .y = found.y,
        };
    }

    var width: u32 = 0;
    var height: u32 = 0;
    for (pages.items) |page| {
        width = @max(width, page.width);
        height = @max(height, page.height);
    }
    return .{
        .placements = placements,
        .pageCount = @intCast(pages.items.len),
        .width = width,
        .height = height,
    };
}

// 优先沿较短方向扩展页面，尺寸不超过配置的上限。
fn grow(
    allocator: std.mem.Allocator,
    page: *PackPage,
    width: u32,
    height: u32,
    maxSize: u32,
) !bool {
    const growDown = page.width > page.height;
    for ([_]bool{ growDown, !growDown }) |down| {
        const newWidth = if (down)
            @max(page.width, width)
        else
            page.width + width;
        const newHeight = if (down)
            page.height + height
        else
            @max(page.height, height);
        if (newWidth > maxSize or newHeight > maxSize) continue;

        const oldWidth = page.width;
        const oldHeight = page.height;
        if (newWidth > oldWidth) {
            try page.free.append(allocator, .{
                .x = oldWidth,
                .y = 0,
                .width = newWidth - oldWidth,
                .height = newHeight,
            });
        }
        if (newHeight > oldHeight) {
            try page.free.append(allocator, .{
                .x = 0,
                .y = oldHeight,
                .width = newWidth,
                .height = newHeight - oldHeight,
            });
        }
        prune(&page.free);
        page.width = newWidth;
        page.height = newHeight;
        return true;
    }
    return false;
}

const SortContext = struct { items: []const PackItem, sort: Sort };
// 大图优先放置，尺寸相同时按路径确定顺序。
fn sortItems(context: SortContext, a: usize, b: usize) bool {
    const itemA = context.items[a];
    const itemB = context.items[b];
    const edgeA = @max(itemA.width, itemA.height);
    const edgeB = @max(itemB.width, itemB.height);
    const areaA = @as(u64, itemA.width) * itemA.height;
    const areaB = @as(u64, itemB.width) * itemB.height;

    switch (context.sort) {
        .edge => {
            if (edgeA != edgeB) return edgeA > edgeB;
            if (areaA != areaB) return areaA > areaB;
        },
        .area => {
            if (areaA != areaB) return areaA > areaB;
            if (edgeA != edgeB) return edgeA > edgeB;
        },
    }
    return std.mem.lessThan(u8, itemA.path, itemB.path);
}

// 按短边或面积的剩余量选择合适的空闲区域。
fn findCandidate(
    pages: []const PackPage,
    width: u32,
    height: u32,
    fit: Fit,
) ?Candidate {
    var best: ?Candidate = null;
    for (pages, 0..) |page, pageIndex| {
        for (page.free.items) |free| {
            if (free.width < width or free.height < height) continue;
            const remainWidth = free.width - width;
            const remainHeight = free.height - height;
            const short = @min(remainWidth, remainHeight);
            const long = @max(remainWidth, remainHeight);
            const area = @as(u64, free.width) * free.height -
                @as(u64, width) * height;
            const current = Candidate{
                .page = pageIndex,
                .x = free.x,
                .y = free.y,
                .score1 = if (fit == .short) short else area,
                .score2 = if (fit == .short) long else short,
            };
            if (best == null or current.betterThan(best.?)) best = current;
        }
    }
    return best;
}

// 将已占用的矩形从空闲区域中切出。
fn place(allocator: std.mem.Allocator, page: *PackPage, used: Rect) !void {
    var split: std.ArrayListUnmanaged(Rect) = .empty;
    errdefer split.deinit(allocator);

    for (page.free.items) |free| {
        if (!free.intersects(used)) {
            try split.append(allocator, free);
            continue;
        }
        if (used.y > free.y) try split.append(allocator, .{
            .x = free.x,
            .y = free.y,
            .width = free.width,
            .height = used.y - free.y,
        });
        if (used.bottom() < free.bottom()) try split.append(allocator, .{
            .x = free.x,
            .y = used.bottom(),
            .width = free.width,
            .height = free.bottom() - used.bottom(),
        });
        if (used.x > free.x) try split.append(allocator, .{
            .x = free.x,
            .y = free.y,
            .width = used.x - free.x,
            .height = free.height,
        });
        if (used.right() < free.right()) try split.append(allocator, .{
            .x = used.right(),
            .y = free.y,
            .width = free.right() - used.right(),
            .height = free.height,
        });
    }

    page.free.deinit(allocator);
    page.free = split;
    prune(&page.free);
    page.width = @max(page.width, used.right());
    page.height = @max(page.height, used.bottom());
}

// 移除被其他空闲矩形完全包含的区域。
fn prune(rects: *std.ArrayListUnmanaged(Rect)) void {
    var i: usize = 0;
    while (i < rects.items.len) {
        var removed = false;
        var j: usize = 0;
        while (j < rects.items.len) : (j += 1) {
            if (i == j) continue;
            if (!rects.items[j].contains(rects.items[i])) continue;
            _ = rects.orderedRemove(i);
            removed = true;
            break;
        }
        if (!removed) i += 1;
    }
}
