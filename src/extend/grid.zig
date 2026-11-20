const std = @import("std");

const math = @import("../math.zig");

const Allocator = std.mem.Allocator;
const BitSet = std.DynamicBitSetUnmanaged;
const Vector2 = math.Vector2;
const Rect = math.Rect;
const Shape = math.Shape;

pub const Cell = struct {
    x: i32,
    y: i32,

    /// 各分量向零截断，不进行网格坐标换算。
    pub fn fromVector(v: Vector2) Cell {
        return .{ .x = @intFromFloat(v.x), .y = @intFromFloat(v.y) };
    }
};

pub const IndexIter = struct {
    width: i32 = 0,
    min: Cell = .{ .x = 0, .y = 0 },
    max: Cell = .{ .x = -1, .y = -1 },
    current: Cell = .{ .x = 0, .y = 0 },

    pub fn next(self: *IndexIter) ?usize {
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

    pub fn worldToCell(self: Grid, world: Vector2) Cell {
        return Cell.fromVector(world.div(self.cellSize()).floor());
    }

    pub fn worldToIndex(self: Grid, world: Vector2) ?usize {
        return self.cellToIndex(self.worldToCell(world));
    }

    pub fn cellToIndex(self: Grid, cell: Cell) ?usize {
        if (cell.x < 0 or cell.y < 0) return null;
        if (cell.x >= self.width or cell.y >= self.height) return null;
        return @intCast(cell.y * self.width + cell.x);
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

    /// 遍历矩形 [min, max) 覆盖的格子下标，按地图边界裁剪。
    /// 宽高必须非负；宽或高为 0 时返回空迭代器。
    pub fn indicesInRect(self: Grid, rect: Rect) IndexIter {
        std.debug.assert(rect.size.x >= 0 and rect.size.y >= 0);
        if (rect.size.x == 0 or rect.size.y == 0) return .{};
        const rawMin = self.worldToCell(rect.min);
        const last = rect.max().div(self.cellSize()).ceil().sub(.one);
        return self.indicesInCells(rawMin, Cell.fromVector(last));
    }

    // 按网格边界裁剪，min 和 max 均包含在遍历范围内。
    fn indicesInCells(self: Grid, min: Cell, max: Cell) IndexIter {
        const first = Cell{ .x = @max(min.x, 0), .y = @max(min.y, 0) };
        const maxX = @min(max.x, self.width - 1);
        const maxY = @min(max.y, self.height - 1);
        if (first.x > maxX or first.y > maxY) return .{};

        return .{
            .width = self.width,
            .min = first,
            .max = .{ .x = maxX, .y = maxY },
            .current = first,
        };
    }
};

/// 瓦片对齐的静态阻挡位图，支持查询与连续 2D 滑墙移动。
pub const SolidMask = struct {
    grid: Grid,
    bits: BitSet,

    pub fn init(gpa: Allocator, grid: Grid) !SolidMask {
        return .{ .grid = grid, .bits = try .initEmpty(gpa, grid.count()) };
    }

    pub fn deinit(self: *SolidMask, gpa: Allocator) void {
        self.bits.deinit(gpa);
        self.* = undefined;
    }

    pub fn clear(self: *SolidMask) void {
        self.bits.unsetAll();
    }

    pub fn set(self: *SolidMask, index: usize, blocked: bool) void {
        self.bits.setValue(index, blocked);
    }

    /// 设置 rect 覆盖到的整格，按网格边界裁剪。
    pub fn setCellsInRect(self: *SolidMask, rect: Rect, blocked: bool) void {
        var iter = self.grid.indicesInRect(rect);
        while (iter.next()) |index| self.bits.setValue(index, blocked);
    }

    pub fn isBlocked(self: SolidMask, index: usize) bool {
        return self.bits.isSet(index);
    }

    /// 逐个取出合并后的世界坐标矩形，不进行分配。
    /// 结果互不重叠且完整覆盖实心区域，半格等精度由 grid.cell 决定。
    /// 每次 next 清除返回区域的实心位，遍历完成后位图为空。
    /// 迭代期间保持 self 有效，不通过其它途径修改网格或位图。
    pub fn takeRects(self: *SolidMask) RectIter {
        return .{ .mask = self };
    }

    /// 检查形状是否与任意实心瓦片重叠，相切不算。
    pub fn overlaps(self: SolidMask, body: Shape) bool {
        var iter = self.grid.indicesInRect(body.toRect());
        while (iter.next()) |index| {
            if (!self.bits.isSet(index)) continue;
            switch (body) {
                .rect => return true,
                .circle => |circle| {
                    const tile = self.grid.indexToRect(index);
                    if (circle.separate(tile) != null) return true;
                },
            }
        }
        return false;
    }

    /// 按实心瓦片做连续 2D 滑墙移动，返回实际位移。
    /// 剩余位移不超过 math.epsilon 时结束；狭缝中连续微小推进视为阻挡，
    /// 可能舍弃本帧仍较大的剩余位移，避免反复接触而无法结束。
    pub fn slide(self: SolidMask, body: Shape, move: Vector2) Vector2 {
        const epsilon2 = math.epsilon * math.epsilon;
        var moved = Vector2.zero;
        var rem = move;
        var prev: ?Vector2 = null;
        var stalled = false;
        while (rem.length2() > epsilon2) {
            const found = self.sweep(body.move(moved), rem) orelse {
                moved = moved.add(rem);
                break;
            };
            const advance = rem.scale(found.fraction);
            const small = advance.length2() <= epsilon2;
            // 首次微小推进仍调整滑动方向并重查，保证贴墙时可以滑动。
            // 连续两次推进都不超过 math.epsilon 时，结束本帧移动。
            if (stalled and small) break;
            moved = moved.add(advance);
            rem = rem.scale(1 - found.fraction);
            switch (body) {
                .rect => {
                    // 墙面决定滑动方向。只有孤立角点时才用角点的两个轴。
                    const isCorner = found.faces.x == 0 and found.faces.y == 0;
                    const axes = if (isCorner) found.normal else found.faces;
                    if (rem.x * axes.x < 0) rem.x = 0;
                    if (rem.y * axes.y < 0) rem.y = 0;
                },
                .circle => {
                    rem = slideAlong(rem, found.normal);
                    // 旧法线只约束同一位置上的连续接触。
                    if (prev) |normal| {
                        const inward = rem.dot(normal) < -math.epsilon;
                        if (found.fraction == 0 and inward) break;
                    }
                    prev = found.normal;
                },
            }
            stalled = small;
        }
        return moved;
    }

    // 将位移投影到法线切面，并保证转回 f32 后不朝法线内侧偏斜。
    fn slideAlong(rem: Vector2, normal: Vector2) Vector2 {
        const nx: f64 = normal.x;
        const ny: f64 = normal.y;
        const dot = @as(f64, rem.x) * nx + @as(f64, rem.y) * ny;
        if (dot >= 0) return rem;

        // 用实际法线长度投影，避免把近似单位向量当作精确单位向量。
        const along = dot / (nx * nx + ny * ny);
        const x: f32 = @floatCast(rem.x - nx * along);
        const y: f32 = @floatCast(rem.y - ny * along);
        if (@as(f64, x) * nx + @as(f64, y) * ny >= 0) return .xy(x, y);

        // 转回 f32 后若仍朝内，沿法线较大的分量向外舍入。
        const inf = std.math.inf(f32);
        if (@abs(nx) >= @abs(ny)) {
            const fixed: f32 = @floatCast(-@as(f64, y) * ny / nx);
            return .xy(std.math.nextAfter(f32, fixed, if (nx > 0) inf else -inf), y);
        }
        const fixed: f32 = @floatCast(-@as(f64, x) * nx / ny);
        return .xy(x, std.math.nextAfter(f32, fixed, if (ny > 0) inf else -inf));
    }

    pub const Contact = struct {
        /// 首次阻挡接触占请求位移的比例，范围为 [0, 1]，包含终点接触。
        fraction: f32,
        /// 从瓦片朝外的单位法线；同时命中时取按行遍历遇到的第一个。
        normal: Vector2,
        /// 矩形同时接触的轴向面，各分量为 -1、0 或 1，不是单位向量。
        /// 圆形或仅接触矩形角点时为零，此时使用 normal。
        faces: Vector2 = .zero,
    };

    /// body 沿 move 平移，返回实心瓦片的最早阻挡接触，无命中时返回 null。
    /// 允许沿边滑动和相切；初始重叠时允许朝最近的边界退开。
    /// 网格外不阻挡；只查询接触，不修改形状或计算滑墙位移。
    pub fn sweep(self: SolidMask, body: Shape, move: Vector2) ?Contact {
        const bounds = body.toRect();
        const end = bounds.move(move);
        const min = bounds.min.min(end.min);
        const max = bounds.max().max(end.max());
        // 闭区间包含两端相邻格，保证正反方向的终点接触都进入候选。
        const first = min.div(self.grid.cellSize()).ceil().sub(.one);
        const last = self.grid.worldToCell(max);

        const isRect = std.meta.activeTag(body) == .rect;
        var best: ?Contact = null;
        var iter = self.grid.indicesInCells(Cell.fromVector(first), last);
        while (iter.next()) |index| {
            if (!self.bits.isSet(index)) continue;
            const tile = Shape{ .rect = self.grid.indexToRect(index) };
            const found = body.sweep(tile, move) orelse continue;
            if (best == null or found.fraction < best.?.fraction) {
                best = .{ .fraction = found.fraction, .normal = found.normal };
            }
            if (isRect and found.fraction == best.?.fraction) {
                const faces = &best.?.faces;
                if (found.normal.x == 0) faces.y = found.normal.y;
                if (found.normal.y == 0) faces.x = found.normal.x;
            }
        }
        return best;
    }
};

/// 按行扫描，先向右确定宽度，再向下扩展；不保证矩形数量最少。
pub const RectIter = struct {
    mask: *SolidMask,
    index: usize = 0,

    pub fn next(self: *RectIter) ?Rect {
        const mask = self.mask;
        const grid = mask.grid;
        const count = grid.count();
        while (self.index < count) : (self.index += 1) {
            if (mask.bits.isSet(self.index)) break;
        }
        if (self.index == count) return null;

        const width: usize = @intCast(grid.width);
        const start = self.index;
        const rowEnd = start - start % width + width;
        var end = start + 1;
        while (end < rowEnd and mask.bits.isSet(end)) : (end += 1) {}
        const span = end - start;

        // 后续行必须覆盖相同宽度，遇到空格就结束扩展，保留缺口。
        var bottom = start + width;
        rows: while (bottom < count) : (bottom += width) {
            for (bottom..bottom + span) |i| {
                if (!mask.bits.isSet(i)) break :rows;
            }
        }

        // 只消费本次返回的区域，中途停止时其余实心位仍然保留。
        var row = start;
        while (row < bottom) : (row += width) {
            mask.bits.setRangeValue(.{ .start = row, .end = row + span }, false);
        }
        const size = grid.cellToWorld(.{
            .x = @intCast(span),
            .y = @intCast((bottom - start) / width),
        });
        self.index = end;
        return .init(grid.indexToWorld(start), size);
    }
};

/// 静态网格索引，按格子返回候选矩形下标的连续切片。
pub const StaticIndex = struct {
    offsets: []u32,
    ids: []u32,

    /// 按 rects 的下标建立静态网格索引，忽略宽或高为 0 的空矩形。
    /// 不保存矩形数据；矩形移动、扩大或 rects 重排后需重建索引。
    pub fn build(gpa: Allocator, grid: Grid, rects: []const Rect) !StaticIndex {
        // 1. 分配格子偏移表，多留一位存总长度。
        const count = grid.count();
        const offsets = try gpa.alloc(u32, count + 1);
        errdefer gpa.free(offsets);
        @memset(offsets, 0);

        // 2. 统计每个格子被多少个矩形覆盖。
        for (rects) |rect| {
            var iter = grid.indicesInRect(rect);
            while (iter.next()) |index| offsets[index] += 1;
        }

        // 3. 前缀累加，原地算出每个格子的结束位置。
        var total: u32 = 0;
        for (offsets[0..count]) |*end| {
            total += end.*;
            end.* = total;
        }
        offsets[count] = total;

        // 4. 从每格末尾往前填入下标；倒序遍历 rects 使同格内保持升序。
        const ids = try gpa.alloc(u32, total);
        var i = rects.len;
        while (i > 0) {
            i -= 1;
            var iter = grid.indicesInRect(rects[i]);
            while (iter.next()) |index| {
                offsets[index] -= 1;
                ids[offsets[index]] = @intCast(i);
            }
        }
        return .{ .offsets = offsets, .ids = ids };
    }

    pub fn deinit(self: *StaticIndex, gpa: Allocator) void {
        gpa.free(self.ids);
        gpa.free(self.offsets);
        self.* = undefined;
    }

    /// 返回指定格子的候选矩形下标，按升序排列，不进行精确相交检测。
    /// 跨格查询可能重复返回同一下标，切片有效期到索引释放为止。
    pub fn idsAt(self: StaticIndex, index: usize) []const u32 {
        return self.ids[self.offsets[index]..self.offsets[index + 1]];
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
