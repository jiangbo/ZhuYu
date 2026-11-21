const std = @import("std");

const assets = @import("../assets.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const Grid = @import("spatial.zig").Grid;

const Vector2 = math.Vector2;
const Rect = math.Rect;

pub const Map = struct {
    grid: Grid,

    backgroundColor: ?graphics.Color = null,
    layers: []const Layer = &.{},
    tileSets: []const TileSet = &.{},

    pub fn getTileSet(self: Map, gid: u32) TileSet {
        std.debug.assert(gid != 0);
        return self.tileSets[(gid >> 24) - 1];
    }

    pub fn getTile(self: Map, gid: u32) ?*const Tile {
        const tileSet = self.getTileSet(gid);
        return tileSet.getTileByLocalId(gid & 0x00FFFFFF);
    }

    pub fn getImage(self: Map, gid: u32) ?graphics.Image {
        const tileSet = self.getTileSet(gid);
        const localId = gid & 0x00FFFFFF;

        if (tileSet.columns == 0) {
            const tile = tileSet.getTileByLocalId(localId).?;
            return assets.getImage(tile.id);
        }
        if (tileSet.image == 0) return null;

        const x: f32 = @floatFromInt(localId % tileSet.columns);
        const y: f32 = @floatFromInt(localId / tileSet.columns);
        const position = tileSet.tileSize.mul(.xy(x, y));
        const area = Rect.init(position, tileSet.tileSize);
        const image = assets.getImage(tileSet.image) orelse return null;
        return image.sub(area);
    }

    pub fn getAnimation(self: Map, gid: u32) ?graphics.Animation {
        const tileSet = self.getTileSet(gid);
        const localId = gid & 0x00FFFFFF;
        if (tileSet.getTileByLocalId(localId)) |tile| {
            if (tile.animation.len == 0) return null;
            return graphics.Animation.initSource(.{
                .imageId = tileSet.image,
                .size = tileSet.tileSize,
                .frames = tile.animation,
            });
        } else return null;
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

pub const LayerEnum = enum { image, tile, object };

pub const Layer = struct {
    id: u32,
    name: []const u8,
    image: u32,
    type: LayerEnum,

    width: f32 = 0,
    height: f32 = 0,

    offset: Vector2,

    // tile 层特有
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
    pub fn grid(self: Layer, cell: u32) Grid {
        std.debug.assert(self.type == .tile);
        return .{
            .width = @intFromFloat(self.width),
            .height = @intFromFloat(self.height),
            .cell = cell,
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

pub const PropertyValue = union(PropertyEnum) {
    string: []const u8, // 字符串值
    int: i32, // 整数值
    float: f32, // 浮点数值
    bool: bool, // 布尔值
    object: i32, // 引用物体 ID
    class: ClassProperty, // Tiled 1.8+ 类属性

    pub fn get(self: PropertyValue, comptime T: type) ?T {
        if (T == []const u8) return self.string;
        if (T == bool) return self.bool;
        if (T == ClassProperty) return self.class;
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
            if (property.is(name)) return property.value.get(T);
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
    tiles: []const Tile,

    pub fn getTileByLocalId(self: TileSet, localId: u32) ?*const Tile {
        if (self.columns == 0) return &self.tiles[localId];
        for (self.tiles) |*tile| {
            if (localId == tile.id) return tile;
        } else return null;
    }
};

pub const Tile = struct {
    id: u32,
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

pub const ObjectExtend = struct {
    flipX: bool = false, // 水平翻转
    flipY: bool = false, // 垂直翻转
    rotation: bool = false, // 旋转90度
    padding: u5 = 0,
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
    extend: ObjectExtend, // 扩展信息

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
