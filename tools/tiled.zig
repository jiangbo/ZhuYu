//! 一次生成全部 Tiled 瓦片集和地图，共用同一份瓦片集顺序。
const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const zhu = @import("zhu");
const tiled = zhu.extend.tiled;

pub const Options = struct {
    input: []const u8, // 资源根目录，与 atlas 的 input 相同，递归读取 TSJ/TMJ。
    output: []const u8 = "src/zon", // 地图保留相对于 input 的目录结构。
    name: []const u8 = "tiled",
};

// 路径通过运行参数传入，多组资源共用同一个工具编译结果。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) void {
    const tool = b.addExecutable(.{
        .name = "zhuyu-tiled",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/tiled.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    // 只使用引擎的数据类型，宿主工具按需分析这些声明。
    tool.root_module.addAnonymousImport("zhu", .{
        .root_source_file = dep.path("src/root.zig"),
    });
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    for ([_][]const u8{ options.input, options.output }) |path| {
        const absolute = b.root.joinString(b.allocator, path) catch
            @panic("out of memory");
        run.addArg(absolute);
    }
    // 每次执行都扫描全部文件，新增的地图与瓦片集也会一起生成。
    run.has_side_effects = true;
    b.step(options.name, "Generate Tiled tilesets and maps").dependOn(&run.step);
}

// 将地图文件内的 GID 区间映射到本次生成的瓦片集顺序。
const TileSetRange = struct { index: u8, firstGid: u32, endGid: u32 };

// 参数依次为资源根目录、ZON 输出目录，所有资源 ID 均相对于根目录计算。
// 瓦片集数据保留到所有地图生成结束，地图临时数据逐张释放。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const root = try std.fs.path.resolveAlloc(allocator, &.{args[1]});
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var tileSets: std.ArrayList(tiled.TileSet) = .empty;
    var maps: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const extension = std.fs.path.extension(entry.path);
        if (std.mem.eql(u8, extension, ".tmj")) {
            try maps.append(allocator, try allocator.dupe(u8, entry.path));
        } else if (std.mem.eql(u8, extension, ".tsj")) {
            const path = try std.fs.path.join(allocator, &.{ root, entry.path });
            const convert = Convert{
                .allocator = allocator,
                .root = root,
                .directory = std.fs.path.dirname(path).?,
            };
            const content = try dir.readFileAlloc(
                io,
                entry.path,
                allocator,
                .unlimited,
            );
            const value = try std.json.parseFromSliceLeaky(
                JsonTileSet,
                allocator,
                content,
                .{},
            );
            const id = try convert.fileId(path);
            try tileSets.append(allocator, try convert.parseTileSet(id, value));
        }
    }
    std.mem.sort(tiled.TileSet, tileSets.items, {}, struct {
        fn lessThan(_: void, a: tiled.TileSet, b: tiled.TileSet) bool {
            return a.id < b.id;
        }
    }.lessThan);
    const tileSetPath = try std.fs.path.join(allocator, &.{ args[2], "tileSet.zon" });
    try writeZon(io, tileSetPath, tileSets.items);

    for (maps.items) |relative| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const mapAllocator = arena.allocator();
        const path = try std.fs.path.join(mapAllocator, &.{ root, relative });
        const convert = Convert{
            .allocator = mapAllocator,
            .root = root,
            .directory = std.fs.path.dirname(path).?,
        };
        const content = try dir.readFileAlloc(io, relative, mapAllocator, .unlimited);
        const value = try std.json.parseFromSliceLeaky(
            JsonMap,
            mapAllocator,
            content,
            .{},
        );
        const map = try convert.parseMap(value, tileSets.items);
        const name = try std.fmt.allocPrint(mapAllocator, "{s}.zon", .{
            relative[0 .. relative.len - 4],
        });
        const output = try std.fs.path.join(mapAllocator, &.{ args[2], name });
        try writeZon(io, output, map);
        std.log.info("converted map: {s}", .{relative});
    }
    std.log.info("converted {} tilesets and {} maps", .{
        tileSets.items.len, maps.items.len,
    });
}

// 输出类型共用文件写入流程，地图子目录按需创建。
fn writeZon(io: std.Io, path: []const u8, value: anytype) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    // 引擎的类属性包含递归类型，直接使用支持该类型的序列化方法。
    try std.zon.stringify.serializeArbitraryDepth(value, .{}, &writer.interface);
    try writer.interface.flush();
}

// 每个源文件携带所在目录，图片和瓦片集引用均以该文件为起点解析。
const Convert = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    directory: []const u8,

    // 图片和瓦片集统一使用根目录相对路径，图片 ID 与 atlas 保持一致。
    fn fileId(self: Convert, file: []const u8) !u32 {
        const path = try std.fs.path.resolveAlloc(self.allocator, &.{
            self.directory, file,
        });
        const relative = try std.fs.path.relativeAlloc(
            self.allocator,
            self.root,
            null,
            self.root,
            path,
        );
        std.mem.replaceScalar(u8, relative, '\\', '/');
        if (std.mem.eql(u8, relative, "..") or
            std.mem.startsWith(u8, relative, "../") or
            std.fs.path.isAbsolute(relative)) return error.FileOutsideRoot;
        return std.hash.Fnv1a_32.hash(relative);
    }

    // 单图瓦片集保留局部 ID，图片集合按局部 ID 索引图片资源。
    fn parseTileSet(self: Convert, id: u32, value: JsonTileSet) !tiled.TileSet {
        var tiles: []tiled.Tile = &.{};
        if (value.tiles) |definitions| {
            var count: usize = definitions.len;
            if (value.columns == 0) {
                // 显示顺序可以调整，按最大局部 ID 计算容量并保留空洞。
                count = 0;
                for (definitions) |tile| count = @max(count, tile.id + 1);
            }
            tiles = try self.allocator.alloc(tiled.Tile, count);
            if (value.columns == 0) @memset(tiles, std.mem.zeroes(tiled.Tile));
            for (definitions, 0..) |tile, index| {
                var group: ?tiled.ObjectGroup = null;
                if (tile.objectgroup) |old| group = .{
                    .visible = old.visible,
                    .objects = try self.parseObjects(old.objects, null),
                };
                const slot = if (value.columns == 0) tile.id else index;
                tiles[slot] = .{
                    .id = if (value.columns != 0) tile.id else if (tile.image) |image|
                        try self.fileId(image)
                    else
                        0,
                    .objectGroup = group,
                    .properties = try self.parseProperties(tile.properties orelse &.{}),
                    .animation = try self.parseAnimation(tile.animation, value),
                };
            }
        }
        return .{
            .id = id,
            .columns = value.columns,
            .tileCount = @intCast(value.tilecount),
            .image = if (value.image) |image| try self.fileId(image) else 0,
            .tileSize = .{
                .x = @floatFromInt(value.tilewidth),
                .y = @floatFromInt(value.tileheight),
            },
            .tiles = tiles,
        };
    }

    // 动画帧使用当前瓦片集的列数和瓦片尺寸，时间换算成秒。
    fn parseAnimation(
        self: Convert,
        frames: []const JsonFrame,
        set: JsonTileSet,
    ) ![]zhu.graphics.Frame {
        const result = try self.allocator.alloc(zhu.graphics.Frame, frames.len);
        for (result, frames) |*frame, old| frame.* = .{
            .offset = .{
                .x = @floatFromInt((old.tileid % set.columns) * set.tilewidth),
                .y = @floatFromInt((old.tileid / set.columns) * set.tileheight),
            },
            .duration = @as(f32, @floatFromInt(old.duration)) / 1000.0,
        };
        return result;
    }

    // 地图直接使用内存中的瓦片集顺序，不再读取生成的 ZON。
    fn parseMap(
        self: Convert,
        value: JsonMap,
        tileSets: []const tiled.TileSet,
    ) !tiled.Map {
        const ranges = try self.allocator.alloc(TileSetRange, value.tilesets.len);
        for (ranges, value.tilesets, 0..) |*range, old, index| {
            const source = old.source.?;
            const id = try self.fileId(source);
            const globalIndex: u8 = for (tileSets, 0..) |set, slot| {
                if (set.id != id) continue;
                std.debug.assert(slot < 255);
                break @intCast(slot);
            } else std.debug.panic("tileSet is missing: {s}", .{source});
            range.* = .{
                .index = globalIndex,
                .firstGid = old.firstgid,
                .endGid = if (index + 1 < ranges.len)
                    value.tilesets[index + 1].firstgid
                else
                    std.math.maxInt(u32),
            };
        }
        std.debug.assert(value.tilewidth == value.tileheight);
        return .{
            .grid = .{
                .width = value.width,
                .height = value.height,
                .cell = @intCast(value.tilewidth),
            },
            .backgroundColor = if (value.backgroundcolor) |color|
                parseColor(color)
            else
                null,
            .layers = try self.parseLayers(value.layers, ranges),
        };
    }

    // 可见层按源文件顺序紧密写入，隐藏层不占输出位置。
    fn parseLayers(
        self: Convert,
        layers: []const JsonLayer,
        ranges: []const TileSetRange,
    ) ![]tiled.Layer {
        const result = try self.allocator.alloc(tiled.Layer, layers.len);
        var count: usize = 0;
        for (layers) |old| {
            if (!old.visible) continue;
            var layer: tiled.Layer = .{
                .id = old.id,
                .name = old.name,
                .image = 0,
                .type = .tile,
                .width = 0,
                .height = 0,
                .offset = .{ .x = old.offsetx, .y = old.offsety },
                .data = &.{},
                .objects = &.{},
                .parallaxX = old.parallaxx,
                .parallaxY = old.parallaxy,
                .repeatX = old.repeatx orelse false,
                .repeatY = old.repeaty orelse false,
            };
            if (std.mem.eql(u8, old.type, "imagelayer")) {
                layer.type = .image;
                layer.width = @floatFromInt(old.imagewidth orelse 0);
                layer.height = @floatFromInt(old.imageheight orelse 0);
                layer.image = try self.fileId(old.image.?);
            } else if (std.mem.eql(u8, old.type, "tilelayer")) {
                layer.width = @floatFromInt(old.width orelse 0);
                layer.height = @floatFromInt(old.height orelse 0);
                const data = try self.allocator.alloc(u32, old.data.len);
                for (data, old.data) |*gid, raw| gid.* = encodeGid(raw, ranges);
                layer.data = data;
            } else if (std.mem.eql(u8, old.type, "objectgroup")) {
                layer.type = .object;
                layer.objects = try self.parseObjects(old.objects, ranges);
            } else return error.InvalidLayerType;
            result[count] = layer;
            count += 1;
        }
        return result[0..count];
    }

    // 地图对象编码全局 GID，瓦片碰撞对象保留原有局部 GID。
    fn parseObjects(
        self: Convert,
        objects: []const JsonObject,
        ranges: ?[]const TileSetRange,
    ) ![]tiled.Object {
        const result = try self.allocator.alloc(tiled.Object, objects.len);
        for (result, objects) |*object, old| {
            const gid = old.gid orelse 0;
            object.* = .{
                .id = old.id,
                .gid = if (ranges) |list| encodeGid(gid, list) else gid & 0x1FFFFFFF,
                .name = old.name,
                .type = old.type,
                .position = .{ .x = old.x, .y = old.y },
                .size = .{ .x = old.width, .y = old.height },
                .point = old.point,
                .properties = try self.parseProperties(old.properties),
                .extend = .{
                    .flipX = (gid & 0x80000000) != 0,
                    .flipY = (gid & 0x40000000) != 0,
                    .rotation = (gid & 0x20000000) != 0,
                },
            };
        }
        return result;
    }

    // 瓦片和地图对象共用同一份属性转换。
    fn parseProperties(
        self: Convert,
        properties: []const JsonProperty,
    ) ![]tiled.Property {
        const result = try self.allocator.alloc(tiled.Property, properties.len);
        for (result, properties) |*property, old| property.* = .{
            .name = old.name,
            .value = try self.parsePropertyValue(old),
        };
        return result;
    }

    // 按 Tiled 声明的属性类型读取 JSON 值。
    fn parsePropertyValue(self: Convert, property: JsonProperty) !tiled.PropertyValue {
        const tag = std.meta.stringToEnum(tiled.PropertyEnum, property.type).?;
        return switch (tag) {
            .string => .{ .string = property.value.string },
            .int => .{ .int = @intCast(property.value.integer) },
            .float => switch (property.value) {
                .float => |value| .{ .float = @floatCast(value) },
                .integer => |value| .{ .float = @floatFromInt(value) },
                else => @panic("Expected a number type for .float"),
            },
            .bool => .{ .bool = property.value.bool },
            .object => .{ .object = @intCast(property.value.integer) },
            .class => .{ .class = .{
                .type = property.propertytype orelse return error.MissingClassType,
                .properties = try self.parseClassProperties(property.value),
            } },
        };
    }

    // 类属性沿用现有格式，数字成员统一保存为浮点数。
    fn parseClassProperties(self: Convert, value: std.json.Value) ![]tiled.Property {
        var object = switch (value) {
            .object => |object| object,
            else => return error.InvalidClassProperty,
        };
        const result = try self.allocator.alloc(tiled.Property, object.count());
        var iterator = object.iterator();
        for (result) |*member| {
            const entry = iterator.next().?;
            member.* = .{
                .name = entry.key_ptr.*,
                .value = switch (entry.value_ptr.*) {
                    .string => |v| .{ .string = v },
                    .integer => |v| .{ .float = @floatFromInt(v) },
                    .float => |v| .{ .float = @floatCast(v) },
                    .bool => |v| .{ .bool = v },
                    else => return error.InvalidClassMemberValue,
                },
            };
        }
        return result;
    }
};

// 高八位存瓦片集序号加一，低二十四位存瓦片集内的局部 ID。
fn encodeGid(gid: u32, ranges: []const TileSetRange) u32 {
    if (gid == 0) return 0;
    const cleanGid = gid & 0x1FFFFFFF;
    for (ranges) |range| {
        if (cleanGid < range.firstGid or cleanGid >= range.endGid) continue;
        const localId = cleanGid - range.firstGid;
        std.debug.assert(localId <= 0x00FFFFFF);
        return ((@as(u32, range.index) + 1) << 24) | localId;
    }
    std.debug.panic("tiled compiler: GID {} has no matching tileSet", .{gid});
}

// Tiled 使用 RRGGBB 或 AARRGGBB，六位颜色默认不透明。
fn parseColor(text: []const u8) zhu.Color {
    const hex = if (text[0] == '#') text[1..] else text;
    std.debug.assert(hex.len == 6 or hex.len == 8);
    const value = std.fmt.parseInt(u32, hex, 16) catch unreachable;
    const alpha: u32 = if (hex.len == 6) 255 else value >> 24;
    return .{
        .r = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
        .a = @as(f32, @floatFromInt(alpha)) / 255.0,
    };
}

// Tiled JSON 输入结构，字段名与源文件一致。
/// Tiled 地图根对象
const JsonMap = struct {
    /// 背景颜色，十六进制格式 (#RRGGBB 或 #AARRGGBB) (可选)
    backgroundcolor: ?[]const u8 = null,
    /// 地图的类 (自 1.9 版本起，可选)
    class: ?[]const u8 = null,
    /// 用于瓦片图层数据的压缩级别 (默认 -1，表示使用算法默认值)
    compressionlevel: i32 = -1,
    /// 瓦片行数 (高度)
    height: i32,
    /// 六边形瓦片边长（以像素为单位，仅适用于六边形地图）
    hexsidelength: ?i32 = null,
    /// 地图是否具有无限维度
    infinite: bool,
    /// 图层数组 (包含瓦片层、对象层、组等)
    layers: []JsonLayer,
    /// 每个新图层的自动递增 ID
    nextlayerid: i32,
    /// 每个新放置对象的自动递增 ID
    nextobjectid: i32,
    /// 地图方向 (orthogonal: 正交, isometric: 等轴, staggered: 交错, hexagonal: 六边形)
    orientation: []const u8,
    /// 视差原点的 X 坐标 (以像素为单位，自 1.8 起，默认: 0)
    parallaxoriginx: f32 = 0,
    /// 视差原点的 Y 坐标 (以像素为单位，自 1.8 起，默认: 0)
    parallaxoriginy: f32 = 0,
    /// 自定义属性数组
    properties: ?[]const JsonProperty = null,
    /// 渲染顺序 (right-down (默认), right-up, left-down 或 left-up；目前仅支持正交地图)
    renderorder: []const u8 = "right-down",
    /// 交错轴 (x 或 y，仅适用于交错/六边形地图)
    staggeraxis: ?[]const u8 = null,
    /// 交错索引 (odd: 奇数 或 even: 偶数，仅适用于交错/六边形地图)
    staggerindex: ?[]const u8 = null,
    /// 用于保存文件的 Tiled 版本
    tiledversion: []const u8,
    /// 地图网格高度 (像素)
    tileheight: i32,
    /// 关联的瓦片集 (JsonTileSet) 数组
    tilesets: []const JsonTileSet,
    /// 地图网格宽度 (像素)
    tilewidth: i32,
    /// 类型 (固定为 "map"，自 1.0 起)
    type: []const u8 = "map",
    /// JSON 格式版本 (自 1.6 起保存为字符串)
    version: []const u8,
    /// 瓦片列数 (宽度)
    width: i32,
};

// --- 图层与块 ---

/// 图层对象 (涵盖 Tile JsonLayer, JsonObject JsonLayer, Image JsonLayer 和 Group)
const JsonLayer = struct {
    /// 块数组 (仅限瓦片图层 tilelayer，用于无限地图)
    chunks: ?[]const JsonChunk = null,
    /// 图层的类 (自 1.9 起，可选)
    class: ?[]const u8 = null,
    /// 压缩算法 (zlib, gzip, zstd 或空，仅限瓦片图层)
    compression: ?[]const u8 = null,
    /// 瓦片数据 (无符号整数数组 GIDs 或 base64 编码字符串，仅限瓦片图层)
    data: []u32 = &.{},
    /// 物体绘制顺序 (topdown (默认) 或 index，仅限对象层 objectgroup)
    draworder: ?[]const u8 = "topdown",
    /// 数据编码格式 (csv (默认) 或 base64，仅限瓦片图层)
    encoding: ?[]const u8 = "csv",
    /// 行数。对于固定大小地图，与地图高度相同 (仅限瓦片图层)
    height: ?i32 = null,
    /// 唯一的增量 ID，在所有图层中唯一
    id: u32 = 0,
    /// 该图层使用的图像路径 (仅限图像图层 imagelayer)
    image: ?[]const u8 = null,
    /// 图像高度 (像素，仅限图像图层)
    imageheight: ?i32 = null,
    /// 图像宽度 (像素，仅限图像图层)
    imagewidth: ?i32 = null,
    /// 子图层数组 (仅限图层组 group)
    layers: ?[]JsonLayer = null,
    /// 是否在编辑器中被锁定 (自 1.8.2，默认: false)
    locked: bool = false,
    /// 分配给该图层的名称
    name: []const u8,
    /// 物体数组 (仅限对象层 objectgroup)
    objects: []JsonObject = &.{},
    /// 水平图层偏移 (像素，默认: 0)
    offsetx: f32 = 0,
    /// 垂直图层偏移 (像素，默认: 0)
    offsety: f32 = 0,
    /// 透明度值 (0 到 1 之间)
    opacity: f32 = 1.0,
    /// 水平视差因子 (自 1.5，默认: 1)
    parallaxx: f32 = 1.0,
    /// 垂直视差因子 (自 1.5，默认: 1)
    parallaxy: f32 = 1.0,
    /// 自定义属性数组
    properties: ?[]const JsonProperty = null,
    /// 图像是否在 X 轴重复 (自 1.8，仅限图像层)
    repeatx: ?bool = null,
    /// 图像是否在 Y 轴重复 (自 1.8，仅限图像层)
    repeaty: ?bool = null,
    /// 图层内容起始 X 坐标 (针对无限地图)
    startx: ?i32 = null,
    /// 图层内容起始 Y 坐标 (针对无限地图)
    starty: ?i32 = null,
    /// 乘法色 (#RRGGBB 或 #AARRGGBB，可选)
    tintcolor: ?[]const u8 = null,
    /// 透明颜色 (#RRGGBB，可选，仅限图像层)
    transparentcolor: ?[]const u8 = null,
    /// 图层类型 (tilelayer, objectgroup, imagelayer 或 group)
    type: []const u8,
    /// 图层在编辑器中是否可见
    visible: bool = true,
    /// 列数。对于固定大小地图，与地图宽度相同 (仅限瓦片图层)
    width: ?i32 = null,
    /// 水平偏移（瓦片单位，始终为 0）
    x: i32 = 0,
    /// 垂直偏移（瓦片单位，始终为 0）
    y: i32 = 0,
};

/// 块对象 (用于存储无限地图的瓦片图层数据)
const JsonChunk = struct {
    /// 瓦片数据 (GIDs 数组或 base64 编码字符串)
    data: std.json.Value,
    /// 以瓦片为单位的高度
    height: i32,
    /// 以瓦片为单位的宽度
    width: i32,
    /// 以瓦片为单位的 X 坐标
    x: i32,
    /// 以瓦片为单位的 Y 坐标
    y: i32,
};

// --- 物体与文本 ---

/// 物体对象 (位于 JsonObject JsonLayer)
const JsonObject = struct {
    /// 是否将该物体标记为椭圆
    ellipse: bool = false,
    /// 全局瓦片 ID (GID)，仅当该物体代表一个瓦片时存在
    gid: ?u32 = null,
    /// 以像素为单位的高度
    height: f32,
    /// 唯一的增量 ID
    id: u32,
    /// 物体名称
    name: []const u8,
    /// 是否将该物体标记为点
    point: bool = false,
    /// 坐标点数组 (如果该物体是多边形 polygon)
    polygon: ?[]const JsonPoint = null,
    /// 坐标点数组 (如果该物体是折线 polyline)
    polyline: ?[]const JsonPoint = null,
    /// 自定义属性数组
    properties: []JsonProperty = &.{},
    /// 顺时针旋转角度 (度数)
    rotation: f32,
    /// 模板文件的引用 (如果是模板实例)
    template: ?[]const u8 = null,
    /// 文本属性 (仅适用于文本对象)
    text: ?JsonText = null,
    /// 物体的类 (自 1.9 起，之前保存为 class)
    type: []const u8,
    /// 物体在编辑器中是否可见
    visible: bool,
    /// 以像素为单位的宽度
    width: f32,
    /// 以像素为单位的 X 坐标
    x: f32,
    /// 以像素为单位的 Y 坐标
    y: f32,
};

/// 文本对象属性
const JsonText = struct {
    /// 是否使用粗体 (默认: false)
    bold: bool = false,
    /// 十六进制格式颜色 (默认: #000000)
    color: []const u8 = "#000000",
    /// 字体族 (默认: sans-serif)
    fontfamily: []const u8 = "sans-serif",
    /// 水平对齐 (center, right, justify 或 left (默认))
    halign: []const u8 = "left",
    /// 是否使用斜体 (默认: false)
    italic: bool = false,
    /// 放置字符时是否使用字距调整 (默认: true)
    kerning: bool = true,
    /// 字体的像素大小 (默认: 16)
    pixelsize: i32 = 16,
    /// 是否带有删除线 (默认: false)
    strikeout: bool = false,
    /// 文本内容
    text: []const u8,
    /// 是否带有下划线 (默认: false)
    underline: bool = false,
    /// 垂直对齐 (center, bottom 或 top (默认))
    valign: []const u8 = "top",
    /// 文本是否在物体范围内换行 (默认: false)
    wrap: bool = false,
};

// --- 瓦片集相关 ---

/// 瓦片集 (JsonTileSet)
const JsonTileSet = struct {
    /// 背景颜色 (可选)
    backgroundcolor: ?[]const u8 = null,
    /// 瓦片集的类 (自 1.9 起，可选)
    class: ?[]const u8 = null,
    /// 瓦片集中的列数
    columns: u32 = 0,
    /// 渲染此瓦片集时的填充模式 (stretch (默认) 或 preserve-aspect-fit)
    fillmode: []const u8 = "stretch",
    /// 对应于集合中第一个瓦片的全局 ID (GID)
    firstgid: u32 = 0,
    /// 网格设置 (可选)
    grid: ?JsonGrid = null,
    /// 瓦片集使用的图像路径
    image: ?[]const u8 = null,
    /// 源图像的高度 (像素)
    imageheight: ?i32 = null,
    /// 源图像的宽度 (像素)
    imagewidth: ?i32 = null,
    /// 图像边缘与第一个瓦片之间的间距 (像素)
    margin: i32 = 0,
    /// 瓦片集名称
    name: []const u8 = &.{},
    /// 瓦片物体的对齐方式 (默认 unspecified)
    objectalignment: []const u8 = "unspecified",
    /// 自定义属性数组
    properties: ?[]const JsonProperty = null,
    /// 包含此瓦片集数据的外部文件路径
    source: ?[]const u8 = null,
    /// 图像中相邻瓦片之间的间距 (像素)
    spacing: i32 = 0,
    /// 地形定义数组 (可选)
    terrains: ?[]const JsonTerrain = null,
    /// 此瓦片集中的瓦片数量
    tilecount: u32 = 0,
    /// 用于保存文件的 Tiled 版本
    tiledversion: ?[]const u8 = null,
    /// 此集合中瓦片的最大高度
    tileheight: u32 = 0,
    /// 瓦片偏移 (可选)
    tileoffset: ?JsonTileOffset = null,
    /// 渲染瓦片大小时使用的参考 (tile (默认) 或 grid)
    tilerendersize: []const u8 = "tile",
    /// 特殊瓦片定义的数组 (可选)
    tiles: ?[]JsonTileDefinition = null,
    /// 此集合中瓦片的最大宽度
    tilewidth: u32 = 0,
    /// 允许的变换 (可选)
    transformations: ?JsonTransformations = null,
    /// 透明颜色 (#RRGGBB，可选)
    transparentcolor: ?[]const u8 = null,
    /// 类型 (固定为 "tileset")
    type: []const u8 = "tileset",
    /// JSON 格式版本
    version: ?[]const u8 = null,
    /// Wang 集合数组 (自 1.1.5)
    wangsets: ?[]const JsonWangSet = null,
};

/// 瓦片定义 (JsonTileSet 中的具体瓦片特殊设置)
const JsonTileDefinition = struct {
    /// 动画帧数组
    animation: []JsonFrame = &.{},
    /// 瓦片的局部 ID
    id: u32 = 0,
    /// 代表该瓦片的图像路径 (仅限图像集合瓦片集)
    image: ?[]const u8 = null,
    /// 瓦片图像的高度 (像素)
    imageheight: ?i32 = null,
    /// 瓦片图像的宽度 (像素)
    imagewidth: ?i32 = null,
    /// 代表该瓦片的子矩形的 X 位置 (默认: 0)
    x: i32 = 0,
    /// 代表该瓦片的子矩形的 Y 位置 (默认: 0)
    y: i32 = 0,
    /// 子矩形的宽度 (默认为图像宽度)
    width: ?i32 = null,
    /// 子矩形的高度 (默认为图像高度)
    height: ?i32 = null,
    /// 当指定碰撞形状时，类型为 objectgroup 的图层
    objectgroup: ?JsonLayer = null,
    /// 概率：在编辑器中与其他瓦片竞争时被选中的百分比机会
    probability: ?f32 = null,
    /// 自定义属性数组
    properties: ?[]JsonProperty = null,
    /// 瓦片每个角的角点索引 (由 Wang sets 取代)
    terrain: ?[]i32 = null,
    /// 瓦片的类 (自 1.9 起，之前保存为 class)
    type: ?[]const u8 = null,
};

// --- 其他小型组件 ---

/// 网格设置
const JsonGrid = struct {
    /// 单元格高度
    height: i32,
    /// 方向 (orthogonal (默认) 或 isometric)
    orientation: []const u8 = "orthogonal",
    /// 单元格宽度
    width: i32,
};

/// 瓦片渲染偏移
const JsonTileOffset = struct {
    /// 水平偏移 (像素)
    x: i32,
    /// 垂直偏移 (像素，正值为向下)
    y: i32,
};

/// 变换限制
const JsonTransformations = struct {
    /// 瓦片是否可以水平翻转
    hflip: bool,
    /// 瓦片是否可以垂直翻转
    vflip: bool,
    /// 瓦片是否可以以 90 度为增量旋转
    rotate: bool,
    /// 是否保留未变换的瓦片优先
    preferuntransformed: bool,
};

/// 动画帧定义
const JsonFrame = struct {
    /// 帧持续时间 (毫秒)
    duration: i32,
    /// 代表该帧的局部瓦片 ID
    tileid: u32,
};

/// 地形定义
const JsonTerrain = struct {
    /// 地形名称
    name: []const u8,
    /// 自定义属性数组
    properties: ?[]const JsonProperty = null,
    /// 代表该地形的局部瓦片 ID
    tile: i32,
};

/// Wang 集合 (用于自动铺路/瓦片匹配)
const JsonWangSet = struct {
    /// Wang 集合的类 (自 1.9，可选)
    class: ?[]const u8 = null,
    /// Wang 颜色数组
    colors: []const JsonWangColor,
    /// Wang 集合名称
    name: []const u8,
    /// 自定义属性数组
    properties: ?[]const JsonProperty = null,
    /// 代表该集合的局部瓦片 ID
    tile: i32,
    /// 类型 (corner, edge 或 mixed)
    type: []const u8,
    /// Wang 瓦片数组
    wangtiles: []const JsonWangTile,
};

/// Wang 颜色定义
const JsonWangColor = struct {
    /// 类的名称 (自 1.9，可选)
    class: ?[]const u8 = null,
    /// 十六进制颜色代码
    color: []const u8,
    /// 名称
    name: []const u8,
    /// 随机化时使用的概率
    probability: f32,
    /// 自定义属性数组
    properties: ?[]const JsonProperty = null,
    /// 代表该颜色的局部瓦片 ID
    tile: i32,
};

/// Wang 瓦片定义
const JsonWangTile = struct {
    /// 局部瓦片 ID
    tileid: i32,
    /// Wang 颜色索引数组 (uchar[8])
    wangid: [8]u8,
};

/// 自定义属性
const JsonProperty = struct {
    /// 属性名称
    name: []const u8,
    /// 属性类型 (string, int, float, bool, color, file, object 或 class)
    type: []const u8 = "string",
    /// 自定义类型的名称 (如果适用)
    propertytype: ?[]const u8 = null,
    /// 属性值 (使用 std.json.Value 兼容多种基础类型)
    value: std.json.Value,
};

/// 像素坐标点
const JsonPoint = struct {
    /// 水平坐标 (像素)
    x: f32,
    /// 垂直坐标 (像素)
    y: f32,
};

/// 物体模板 (用于实例化重复物体)
const JsonObjectTemplate = struct {
    /// 固定为 "template"
    type: []const u8 = "template",
    /// 模板使用的外部瓦片集 (可选)
    tileset: ?JsonTileSet = null,
    /// 由此模板实例化的物体定义
    object: JsonObject,
};
