const std = @import("std");

const assets = @import("../assets.zig");
const codec = @import("../internal/codec.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const Grid = @import("spatial.zig").Grid;

const Vector2 = math.Vector2;
const Rect = math.Rect;
const Image = graphics.Image;
const Vertex = graphics.Vertex;

/// firstGid 是本地图中的编号起点；id 是按资源路径计算的稳定瓦片集 ID。
pub const TileSetRef = struct { firstGid: u32, id: u32 };

pub const Map = struct {
    grid: Grid,

    backgroundColor: ?graphics.Color = null,
    properties: []const Property = &.{},
    layers: []const Layer = &.{},
    tileSetRefs: []const TileSetRef = &.{}, // 按 firstGid 严格升序。
    tileSets: []const TileSet = &.{}, // 按 id 严格升序，定义由调用方持有。

    pub fn getProperty(self: Map, name: []const u8, T: type) ?T {
        for (self.properties) |property| {
            if (property.is(name)) return property.value.get(T);
        }
        return null;
    }

    pub fn getClass(self: Map, name: []const u8) ?ClassProperty {
        return self.getProperty(name, ClassProperty);
    }

    /// 在本地图已导出的对象层中查找，找不到时返回 null。
    pub fn getObject(self: Map, id: ObjectId) ?*const Object {
        const value = @backingInt(id);
        if (value == 0) return null;
        for (self.layers) |layer| {
            if (layer.type != .object) continue;
            for (layer.objects) |*object| {
                if (object.id == value) return object;
            }
        }
        return null;
    }

    /// 查找 GID 对应的瓦片引用；要求瓦片集已提供，查找失败时报错。
    fn findTileRef(self: Map, raw: u32) struct { *const TileSet, u32 } {
        // 查询定义时清除最高四位；原始 GID 仍保留方向信息，供加载时解析。
        const gid = raw & 0x0FFFFFFF;
        std.debug.assert(gid != 0);
        // 原生 GID 只在本地图内有效，归属于 firstGid 不大于它的最后一项。
        var i = self.tileSetRefs.len;
        while (i != 0) : (i -= 1) {
            const ref = self.tileSetRefs[i - 1];
            if (gid < ref.firstGid) continue;
            // 按稳定 ID 查询定义，不依赖瓦片集在全局数组中的位置。
            const search = std.sort.binarySearch;
            const found = search(TileSet, self.tileSets, ref.id, struct {
                fn compare(id: u32, set: TileSet) std.math.Order {
                    return std.math.order(id, set.id);
                }
            }.compare);
            const index = found orelse
                std.debug.panic("tileSet {} is not loaded", .{ref.id});
            const set = &self.tileSets[index];
            const localId = gid - ref.firstGid;
            if (set.columns != 0) std.debug.assert(localId < set.tileCount) //
            else std.debug.assert(localId < set.tiles.len);
            return .{ set, localId };
        }
        std.debug.panic("GID {} has no tileSet reference", .{gid});
    }

    pub fn getTileSet(self: Map, gid: u32) TileSet {
        return self.findTileRef(gid)[0].*;
    }

    pub fn getTile(self: Map, gid: u32) ?*const Tile {
        const tileSet, const localId = self.findTileRef(gid);
        return tileSet.getTileByLocalId(localId);
    }

    /// 返回未翻转的子图；翻转和旋转由 TileExtend 在绘制时应用。
    pub fn getImage(self: Map, gid: u32) ?Image {
        const tileSet, const localId = self.findTileRef(gid);
        if (tileSet.columns == 0) {
            const tile = tileSet.getTileByLocalId(localId).?;
            const image = assets.getImage(tile.id) orelse return null;
            return if (tile.imageRect) |rect| image.sub(rect) else image;
        }
        if (tileSet.image == 0) return null;
        const image = assets.getImage(tileSet.image) orelse return null;
        const offset = tileSet.tileOffset(localId);
        return image.sub(.init(offset, tileSet.tileSize));
    }

    pub fn getAnimation(self: Map, gid: u32) ?graphics.Animation {
        const tileSet, const localId = self.findTileRef(gid);
        const tile = tileSet.getTileByLocalId(localId) orelse return null;
        if (tile.animation.len == 0) return null;
        return graphics.Animation.initSource(.{
            .imageId = tileSet.image,
            .size = tileSet.tileSize,
            .frames = tile.animation,
        });
    }
};

const Maps = []const Map;
pub fn bind(comptime ts: []const TileSet, comptime list: Maps) Maps {
    const result = comptime blk: {
        var result: [list.len]Map = undefined;
        for (list, 0..) |map, index| {
            result[index] = map;
            result[index].tileSets = ts;
        }
        break :blk result;
    };
    return &result;
}

/// 解码单张地图的原始字节。建议用 arena 统一释放解码分配。
pub fn decodeMap(bytes: []const u8, gpa: std.mem.Allocator) !Map {
    return decode(Map, bytes, gpa);
}

/// 解码拆分输出的单个瓦片集。建议用 arena 统一释放解码分配。
pub fn decodeTileSet(bytes: []const u8, gpa: std.mem.Allocator) !TileSet {
    return decode(TileSet, bytes, gpa);
}

/// 解码合并输出的瓦片集。建议用 arena 统一释放解码分配。
pub fn decodeTileSets(bytes: []const u8, gpa: std.mem.Allocator) ![]const TileSet {
    return decode([]const TileSet, bytes, gpa);
}

fn decode(comptime T: type, bytes: []const u8, gpa: std.mem.Allocator) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    const result = try codec.decode(&reader, T, gpa);
    if (reader.bufferedLen() != 0) return error.InvalidData;
    return result;
}

pub const LayerEnum = enum { image, tile, object };

pub const Layer = struct {
    id: u32,
    name: []const u8,
    image: u32,
    type: LayerEnum,

    width: f32 = 0,
    height: f32 = 0,

    offset: Vector2,

    // tile 层特有：保留 Tiled 原生 GID，最高四位是方向标志，0 表示空格。
    data: []const u32,

    // 对象层特有
    objects: []const Object,

    // 图片层
    parallaxX: f32 = 1.0,
    parallaxY: f32 = 1.0,
    repeatX: bool = false,
    repeatY: bool = false,

    pub fn isNamed(self: Layer, name: []const u8) bool {
        return std.mem.eql(u8, self.name, name);
    }

    /// 根据地图瓦片尺寸返回当前 tile 层的网格。
    pub fn grid(self: Layer, cellSide: u32) Grid {
        std.debug.assert(self.type == .tile);
        return .{
            .width = @intFromFloat(self.width),
            .height = @intFromFloat(self.height),
            .cellSide = cellSide,
        };
    }
};

pub const PropertyEnum = enum {
    string,
    int,
    float,
    bool,
    object,
    class,
};

pub const ObjectId = enum(u32) {
    _,

    fn fromInt(id: u32) ?ObjectId {
        return if (id == 0) null else @fromBackingInt(id);
    }
};

pub const PropertyValue = union(PropertyEnum) {
    string: []const u8, // 字符串值
    int: i64, // 整数值
    float: f32, // 浮点数值
    bool: bool, // 布尔值
    object: u32, // 引用物体 ID，0 表示未设置。
    class: ClassProperty, // Tiled 1.8+ 类属性

    pub fn get(self: PropertyValue, comptime T: type) ?T {
        if (T == []const u8) return self.string;
        if (T == bool) return self.bool;
        if (T == ClassProperty) return self.class;
        if (T == ObjectId) return ObjectId.fromInt(self.object);
        if (@typeInfo(T) == .int) return @intCast(self.int);
        if (@typeInfo(T) == .float) return @floatCast(self.float);
        @compileError("unsupported property type: " ++ @typeName(T));
    }
};

pub const ClassProperty = struct {
    type: []const u8, // 类名，例如 Spotlight
    properties: []const Property, // 类内部成员

    pub fn is(self: ClassProperty, typeName: []const u8) bool {
        return std.mem.eql(u8, self.type, typeName);
    }

    pub fn get(self: ClassProperty, name: []const u8, T: type) ?T {
        for (self.properties) |property| {
            if (!property.is(name)) continue;
            const value = property.value;
            if (value == .int) {
                if (T == ObjectId) return ObjectId.fromInt(@intCast(value.int));
                if (@typeInfo(T) == .float) return @floatFromInt(value.int);
            }
            return value.get(T);
        }
        return null;
    }
};

pub const Property = struct {
    name: []const u8, // 属性名称
    value: PropertyValue, // 具体的属性值

    pub fn is(self: Property, name: []const u8) bool {
        return std.mem.eql(u8, self.name, name);
    }
};

pub const TileSet = struct {
    id: u32,
    columns: u32,
    tileCount: i32,
    image: u32,
    tileSize: Vector2,
    margin: u32 = 0,
    spacing: u32 = 0,
    tiles: []const Tile,
    wangSets: []const WangSet = &.{},

    pub fn tileOffset(self: TileSet, localId: u32) Vector2 {
        std.debug.assert(self.columns != 0);
        const col: f32 = @floatFromInt(localId % self.columns);
        const row: f32 = @floatFromInt(localId / self.columns);
        const margin: f32 = @floatFromInt(self.margin);
        const spacing: f32 = @floatFromInt(self.spacing);
        const stride = self.tileSize.add(.all(spacing));
        return stride.mul(.xy(col, row)).add(.all(margin));
    }

    pub fn getWangSet(self: TileSet, name: []const u8) ?*const WangSet {
        for (self.wangSets) |*set| {
            if (std.mem.eql(u8, set.name, name)) return set;
        }
        return null;
    }

    pub fn getTileByLocalId(self: TileSet, localId: u32) ?*const Tile {
        if (self.columns == 0) return &self.tiles[localId];
        for (self.tiles) |*tile| {
            if (localId == tile.id) return tile;
        } else return null;
    }
};

/// Tiled 地形规则；颜色索引从 1 开始，0 表示未标记。
pub const WangSet = struct {
    name: []const u8,
    type: enum { corner, edge, mixed },
    colors: []const []const u8,
    tiles: []const WangTile,

    pub fn getColorIndex(self: WangSet, name: []const u8) ?u8 {
        for (self.colors, 1..) |color, index| {
            if (std.mem.eql(u8, color, name)) return @intCast(index);
        }
        return null;
    }

    /// 按上、右上、右、右下、下、左下、左、左上的顺序精确匹配。
    /// 0 也参与匹配；重复规则取首个，不应用随机概率或近似补全。
    pub fn getTileId(self: WangSet, colors: [8]u8) ?u32 {
        for (self.tiles) |tile| {
            if (std.mem.eql(u8, &tile.colors, &colors)) return tile.tileId;
        }
        return null;
    }
};

pub const WangTile = struct { tileId: u32, colors: [8]u8 };

pub const Tile = struct {
    id: u32,
    imageRect: ?Rect = null, // 图片集合瓦片在源图片中的裁剪区域。
    objectGroup: ?ObjectGroup = null,
    properties: []const Property,
    animation: []const graphics.Frame = &.{},

    pub fn hasProperty(self: Tile, name: []const u8) bool {
        for (self.properties) |property| {
            if (property.is(name)) return true;
        }
        return false;
    }

    pub fn getProperty(self: Tile, name: []const u8, T: type) ?T {
        for (self.properties) |property| {
            if (property.is(name)) return property.value.get(T);
        }
        return null;
    }
};

pub const ObjectGroup = struct {
    visible: bool, // 是否可见
    objects: []const Object, // 物体数组 (物体层用)
};

/// 正交地图的显示标志：先交换坐标轴，再水平、垂直翻转。
pub const TileExtend = struct {
    flipX: bool = false,
    flipY: bool = false,
    rotation: bool = false, // GID 的对角翻转位，与水平、垂直翻转组合表示旋转。

    /// 地图加载时解析，顶点和精灵保存结果；不在绘制时重复拆位。
    /// 正交地图只使用三个方向位，第四个高位由 GID 查询入口统一清除。
    pub fn fromGid(gid: u32) TileExtend {
        return .{
            .flipX = gid & 0x80000000 != 0,
            .flipY = gid & 0x40000000 != 0,
            .rotation = gid & 0x20000000 != 0,
        };
    }

    /// 输入和输出均为 0～1 的瓦片坐标，碰撞与绘制共用相同的方向约定。
    fn point(self: TileExtend, value: Vector2) Vector2 {
        var result = value;
        if (self.rotation) result = .xy(result.y, result.x);
        if (self.flipX) result.x = 1 - result.x;
        if (self.flipY) result.y = 1 - result.y;
        return result;
    }

    /// 输入矩形使用 0～1 的瓦片坐标。
    pub fn rect(self: TileExtend, value: Rect) Rect {
        const a = self.point(value.min);
        const b = self.point(value.max());
        const min = a.min(b);
        return .init(min, a.max(b).sub(min));
    }

    pub fn uvRect(self: TileExtend, value: math.Vector4) math.Vector4 {
        var uv = value;
        // 对角翻转由 vertex 的 90° 旋转配合 UV 翻转实现。
        // 因而需要交换翻转轴，再补一次 Y 翻转，组合成坐标轴交换。
        const x = if (self.rotation) self.flipY else self.flipX;
        const y = if (self.rotation) !self.flipX else self.flipY;
        if (x) uv.x, uv.z = .{ uv.x + uv.z, -uv.z };
        if (y) uv.y, uv.w = .{ uv.y + uv.w, -uv.w };
        return uv;
    }

    pub fn vertex(self: TileExtend, area: Rect, image: Image) Vertex {
        var result = Vertex{
            .position = area.min,
            .size = area.size,
            .layer = image.layer,
            .filter = image.filter,
            .uvRect = self.uvRect(image.uvRect()),
        };
        if (self.rotation) {
            // 绕目标矩形中心旋转，并交换宽高，使非正方形瓦片仍落在原区域内。
            result.position = area.center();
            result.pivot = .center;
            result.size = .xy(area.size.y, area.size.x);
            result.radian = std.math.pi / 2.0;
        }
        return result;
    }
};

pub const Object = struct {
    id: u32,
    gid: u32,
    name: []const u8,
    type: []const u8,
    position: Vector2, // 像素坐标
    size: Vector2, // 像素宽高
    point: bool, // 是否为点物体
    properties: []const Property, // 物体自定义属性
    extend: TileExtend = .{},

    pub fn topLeft(self: Object) Vector2 {
        if (self.gid == 0) return self.position;
        return self.position.addY(-self.size.y);
    }

    pub fn rect(self: Object) Rect {
        return .init(self.topLeft(), self.size);
    }

    pub fn hasProperty(self: Object, name: []const u8) bool {
        for (self.properties) |property| {
            if (property.is(name)) return true;
        }
        return false;
    }

    pub fn getProperty(self: Object, name: []const u8, T: type) ?T {
        for (self.properties) |property| {
            if (property.is(name)) return property.value.get(T);
        }
        return null;
    }

    pub fn getClass(self: Object, name: []const u8) ?ClassProperty {
        return self.getProperty(name, ClassProperty);
    }

    pub fn isNamed(self: Object, name: []const u8) bool {
        return std.mem.eql(u8, self.name, name);
    }

    pub fn isType(self: Object, typeName: []const u8) bool {
        return std.mem.eql(u8, self.type, typeName);
    }
};
