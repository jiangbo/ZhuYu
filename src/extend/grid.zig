const std = @import("std");

const math = @import("../math.zig");

const Vector2 = math.Vector2;
const Rect = math.Rect;

pub const Cell = struct {
    x: i32,
    y: i32,

    pub fn xy(x: i32, y: i32) Cell {
        return .{ .x = x, .y = y };
    }
};

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
        return .all(@floatFromInt(self.cell));
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

    /// 遍历矩形 [min, max) 覆盖的格子，按地图边界裁剪。
    pub fn cellsInRect(self: Grid, rect: Rect) CellRectIter {
        std.debug.assert(rect.size.y > 0 and rect.size.x > 0);

        const rawMin = self.worldToCell(rect.min);
        const last = rect.max().div(self.cellSize()).ceil().sub(.one);
        const rawMax = Cell.xy(@intFromFloat(last.x), @intFromFloat(last.y));

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
        grid: Grid,
        data: []const T = &.{},

        const Self = @This();
        pub const TileScan = Scan(T);

        const Range = struct { first: i32 = 0, count: u32 = 0 };

        pub fn tileAt(self: *const Self, cell: Cell) ?T {
            const index = self.grid.cellToIndex(cell) orelse return null;
            return self.data[index];
        }

        /// 扫描 X 轴移动后的前沿瓦片，返回顺序固定为从上到下
        pub fn scanX(self: *const Self, rect: Rect, dx: f32) TileScan {
            const dest = rect.min.x + dx;
            if (dx == 0) return .{ .dest = dest };

            const size: f32 = @floatFromInt(self.grid.cell);
            const r0: i32 = @intFromFloat(@floor(rect.min.y / size));
            const bottom = rect.min.y + rect.size.y;
            const r1: i32 = @intFromFloat(@ceil(bottom / size) - 1);
            const rows = clipRange(r0, r1, self.grid.height);

            var cellX = @floor(dest / size);
            if (dx > 0) cellX = @ceil((dest + rect.size.x) / size) - 1;
            const col: i32 = @intFromFloat(cellX);

            var touch = (cellX + 1) * size;
            if (dx > 0) touch = cellX * size - rect.size.x;

            const outside = col < 0 or col >= self.grid.width;
            if (outside) return .{ .dest = dest, .touch = touch };

            const width = self.grid.width;
            return .{ .dest = dest, .touch = touch, .state = .{
                .data = self.data,
                .index = rows.first * width + col,
                .remaining = rows.count,
                .step = width,
            } };
        }

        /// 扫描 Y 轴移动后的前沿瓦片，返回顺序固定为从左到右
        pub fn scanY(self: *const Self, rect: Rect, dy: f32) TileScan {
            const dest = rect.min.y + dy;
            if (dy == 0) return .{ .dest = dest };

            const size: f32 = @floatFromInt(self.grid.cell);
            const c0: i32 = @intFromFloat(@floor(rect.min.x / size));
            const right = rect.min.x + rect.size.x;
            const c1: i32 = @intFromFloat(@ceil(right / size) - 1);
            const cols = clipRange(c0, c1, self.grid.width);

            var cellY = @floor(dest / size);
            if (dy > 0) cellY = @ceil((dest + rect.size.y) / size) - 1;
            const row: i32 = @intFromFloat(cellY);

            var touch = (cellY + 1) * size;
            if (dy > 0) touch = cellY * size - rect.size.y;

            const outside = row < 0 or row >= self.grid.height;
            if (outside) return .{ .dest = dest, .touch = touch };

            const width = self.grid.width;
            return .{ .dest = dest, .touch = touch, .state = .{
                .data = self.data,
                .index = row * width + cols.first,
                .remaining = cols.count,
            } };
        }

        fn clipRange(first: i32, last: i32, limit: i32) Range {
            const clippedFirst = @max(first, 0);
            const clippedLast = @min(last, limit - 1);
            if (clippedFirst > clippedLast) return .{};

            return .{
                .first = clippedFirst,
                .count = @intCast(clippedLast - clippedFirst + 1),
            };
        }
    };
}
