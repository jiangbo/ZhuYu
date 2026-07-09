const std = @import("std");

const assets = @import("../assets.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");

pub const Cell = struct {
    x: i32,
    y: i32,

    pub fn xy(x: i32, y: i32) Cell {
        return .{ .x = x, .y = y };
    }
};
const Vector2 = math.Vector2;
const Rect = math.Rect;

pub const Grid = struct {
    width: i32,
    height: i32,
    cell: u32,

    pub fn size(self: Grid) Vector2 {
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        return Vector2.xy(w, h).scale(@floatFromInt(self.cell));
    }

    pub fn count(self: Grid) usize {
        return @intCast(self.width * self.height);
    }

    pub fn cellSize(self: Grid) Vector2 {
        return .square(@floatFromInt(self.cell));
    }

    pub fn halfCell(self: Grid) Vector2 {
        return self.cellSize().scale(0.5);
    }

    pub fn cellToIndex(self: Grid, cell: Cell) ?usize {
        if (cell.x < 0 or cell.y < 0) return null;
        if (cell.x >= self.width or cell.y >= self.height) return null;
        return @intCast(cell.y * self.width + cell.x);
    }

    pub fn worldToIndex(self: Grid, world: Vector2) ?usize {
        return self.cellToIndex(self.worldToCell(world));
    }

    pub fn worldToCell(self: Grid, world: Vector2) Cell {
        const grid = world.div(self.cellSize()).floor();
        return .xy(@intFromFloat(grid.x), @intFromFloat(grid.y));
    }

    pub fn cellToWorld(self: Grid, cell: Cell) Vector2 {
        const x: f32 = @floatFromInt(cell.x);
        const y: f32 = @floatFromInt(cell.y);
        return Vector2.xy(x, y).scale(@floatFromInt(self.cell));
    }

    pub fn indexToWorld(self: Grid, index: usize) Vector2 {
        const width: usize = @intCast(self.width);
        const x: f32 = @floatFromInt(index % width);
        const y: f32 = @floatFromInt(index / width);
        return Vector2.xy(x, y).scale(@floatFromInt(self.cell));
    }

    pub fn indexToRect(self: Grid, index: usize) Rect {
        return .init(self.indexToWorld(index), self.cellSize());
    }

    /// 返回矩形覆盖到的地图内格子，范围会按地图边界裁剪。
    pub fn cellsInRect(self: Grid, rect: Rect) CellRectIter {
        std.debug.assert(rect.size.y > 0 and rect.size.x > 0);

        const rawMin = self.worldToCell(rect.min);
        const max = rect.max().sub(.square(math.epsilon));
        const rawMax = self.worldToCell(max);

        const min = Cell.xy(@max(rawMin.x, 0), @max(rawMin.y, 0));
        const maxX = @min(rawMax.x, self.width - 1);
        const maxY = @min(rawMax.y, self.height - 1);
        if (min.x > maxX or min.y > maxY) return .{};

        return .{
            .width = self.width,
            .min = min,
            .max = .xy(maxX, maxY),
            .current = min,
        };
    }
};

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
            return graphics.Animation.init(
                assets.getImage(tileSet.image).?,
                tileSet.tileSize,
                tile.animation,
            );
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

pub fn Scan(comptime T: type) type {
    return struct {
        dest: f32 = 0,
        touch: f32 = 0,
        state: State = .{},

        const State = struct {
            data: []const T = &.{},
            index: i32 = 0,
            remaining: u32 = 0,
            step: i32 = 1,
        };

        pub fn reversed(self: @This()) @This() {
            var scan = self;
            if (scan.state.remaining > 0) {
                const last: i32 = @intCast(scan.state.remaining - 1);
                scan.state.index += last * scan.state.step;
                scan.state.step = -scan.state.step;
            }
            return scan;
        }

        pub fn next(self: *@This()) ?T {
            if (self.state.remaining == 0) return null;

            const index = self.state.index;
            self.state.index += self.state.step;
            self.state.remaining -= 1;

            std.debug.assert(index >= 0);
            const i: usize = @intCast(index);
            std.debug.assert(i < self.state.data.len);
            return self.state.data[i];
        }
    };
}

pub fn Field(comptime T: type) type {
    return struct {
        map: *const Map,
        data: []const T = &.{},

        const Self = @This();
        pub const TileScan = Scan(T);

        const Edge = struct {
            fixed: i32,
            touch: f32,
        };

        pub fn tileAt(self: *const Self, cell: Cell) ?T {
            self.assertValid();
            const index = self.map.grid.cellToIndex(cell) orelse return null;
            return self.data[index];
        }

        /// 扫描 X 轴移动后的前沿瓦片，返回顺序固定为从上到下
        pub fn scanX(self: *const Self, rect: Rect, dx: f32) TileScan {
            self.assertValid();
            std.debug.assert(rect.size.x > 0 and rect.size.y > 0);

            const dest = rect.min.x + dx;
            if (dx == 0) return .{ .dest = dest };

            const size: f32 = @floatFromInt(self.map.grid.cell);
            const r0 = tileCoord(rect.min.y, size);
            const bottom = rect.min.y + rect.size.y - math.epsilon;
            const r1 = tileCoord(bottom, size);
            const rows = clipRange(r0, r1, self.map.grid.height);

            const edge: Edge = if (dx > 0) right_edge: {
                // 向右时固定目标右边缘所在列。
                const right = dest + rect.size.x - math.epsilon;
                const col = tileCoord(right, size);
                const colf: f32 = @floatFromInt(col);
                const left = colf * size;
                break :right_edge .{
                    .fixed = col,
                    .touch = left - rect.size.x,
                };
            } else left_edge: {
                // 向左时固定目标左边缘所在列。
                const col = tileCoord(dest, size);
                const colf: f32 = @floatFromInt(col);
                const right = (colf + 1) * size;
                break :left_edge .{ .fixed = col, .touch = right };
            };

            const remaining = if (inRange(edge.fixed, self.map.grid.width))
                rows.count
            else
                0;
            const width = self.map.grid.width;
            const index = if (remaining > 0)
                rows.first * width + edge.fixed
            else
                0;
            return .{
                .dest = dest,
                .touch = edge.touch,
                .state = .{
                    .data = self.data,
                    .index = index,
                    .remaining = remaining,
                    .step = width,
                },
            };
        }

        /// 扫描 Y 轴移动后的前沿瓦片，返回顺序固定为从左到右
        pub fn scanY(self: *const Self, rect: Rect, dy: f32) TileScan {
            self.assertValid();
            std.debug.assert(rect.size.x > 0 and rect.size.y > 0);

            const dest = rect.min.y + dy;
            if (dy == 0) return .{ .dest = dest };

            const size: f32 = @floatFromInt(self.map.grid.cell);
            const c0 = tileCoord(rect.min.x, size);
            const right = rect.min.x + rect.size.x - math.epsilon;
            const c1 = tileCoord(right, size);
            const cols = clipRange(c0, c1, self.map.grid.width);

            const edge: Edge = if (dy > 0) bottom_edge: {
                // 向下时固定目标下边缘所在行。
                const targetBottom = dest + rect.size.y - math.epsilon;
                const row = tileCoord(targetBottom, size);
                const rowf: f32 = @floatFromInt(row);
                const top = rowf * size;
                break :bottom_edge .{
                    .fixed = row,
                    .touch = top - rect.size.y,
                };
            } else top_edge: {
                // 向上时固定目标上边缘所在行。
                const row = tileCoord(dest, size);
                const rowf: f32 = @floatFromInt(row);
                const bottom = (rowf + 1) * size;
                break :top_edge .{ .fixed = row, .touch = bottom };
            };

            const remaining = if (inRange(edge.fixed, self.map.grid.height))
                cols.count
            else
                0;
            const width = self.map.grid.width;
            const index = if (remaining > 0)
                edge.fixed * width + cols.first
            else
                0;
            return .{
                .dest = dest,
                .touch = edge.touch,
                .state = .{
                    .data = self.data,
                    .index = index,
                    .remaining = remaining,
                },
            };
        }

        fn assertValid(self: *const Self) void {
            std.debug.assert(self.map.grid.cell > 0);
            std.debug.assert(self.data.len >= self.map.grid.count());
        }
    };
}

pub const CellRectIter = struct {
    width: i32 = 0,
    min: Cell = .xy(0, 0),
    max: Cell = .xy(-1, -1),
    current: Cell = .xy(0, 0),

    pub fn next(self: *CellRectIter) ?usize {
        if (self.current.y > self.max.y) return null;

        const i = self.current.y * self.width + self.current.x;
        self.current.x += 1;
        if (self.current.x > self.max.x) {
            self.current.x = self.min.x;
            self.current.y += 1;
        }
        return @intCast(i);
    }
};

const Range = struct {
    first: i32 = 0,
    count: u32 = 0,
};

fn clipRange(first: i32, last: i32, limit: i32) Range {
    if (last < first or limit == 0) return .{};
    if (last < 0) return .{};

    if (first >= limit) return .{};

    const clippedFirst = @max(first, 0);
    const clippedLast = @min(last, limit - 1);
    return .{
        .first = clippedFirst,
        .count = @intCast(clippedLast - clippedFirst + 1),
    };
}

fn inRange(index: i32, limit: i32) bool {
    if (index < 0) return false;
    return index < limit;
}

fn tileCoord(value: f32, size: f32) i32 {
    std.debug.assert(size > 0);
    return @intFromFloat(@floor(value / size));
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
    tileSize: graphics.Vector2,
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

pub var backgroundColor: ?graphics.Color = null;
