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
    cellSide: u32,

    pub fn size(self: Grid) Vector2 {
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        return Vector2.xy(w, h).scale(@floatFromInt(self.cellSide));
    }

    pub fn count(self: Grid) usize {
        return @intCast(self.width * self.height);
    }

    pub fn cellSize(self: Grid) Vector2 {
        return .all(@floatFromInt(self.cellSide));
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
        return Vector2.xy(x, y).scale(@floatFromInt(self.cellSide));
    }

    pub fn indexToWorld(self: Grid, index: usize) Vector2 {
        const width: usize = @intCast(self.width);
        const x: f32 = @floatFromInt(index % width);
        const y: f32 = @floatFromInt(index / width);
        return Vector2.xy(x, y).scale(@floatFromInt(self.cellSide));
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

    /// 遍历 rect 沿 move 平移的包围范围，返回候选格子下标。
    /// 宽高必须非负；包含仅接触边界的格子，并按地图边界裁剪。
    pub fn indicesInSweep(self: Grid, rect: Rect, move: Vector2) IndexIter {
        std.debug.assert(rect.size.x >= 0 and rect.size.y >= 0);
        const end = rect.move(move);
        const min = rect.min.min(end.min);
        const max = rect.max().max(end.max());
        const first = min.div(self.cellSize()).ceil().sub(.one);
        const last = self.worldToCell(max);
        return self.indicesInCells(Cell.fromVector(first), last);
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

    /// 将 body 限制在网格范围 [0, size) 内，返回撞到边界的最早接触。
    pub fn sweepBounds(self: Grid, body: Shape, move: Vector2) ?Contact {
        return sweepBoundsInRect(.init(.zero, self.size()), body, move);
    }
};

/// 将 body 限制在 bounds 矩形内，返回撞到四条内边界的最早接触，无越界返回 null。
/// 贴边或已越界时允许朝矩形内侧移回，仅阻挡继续向外移动。
pub fn sweepBounds(bounds: Rect, body: Shape, move: Vector2) ?Contact {
    return sweepBoundsInRect(bounds, body, move);
}

fn sweepBoundsInRect(bounds: Rect, body: Shape, move: Vector2) ?Contact {
    const box = body.toRect();
    const boxMax = box.max();
    const max = bounds.max();
    const isRect = std.meta.activeTag(body) == .rect;
    var best: ?Contact = null;
    inline for (.{ "x", "y" }) |axis| {
        const delta = @field(move, axis);
        if (delta < 0) {
            const dist = @field(box.min, axis) - @field(bounds.min, axis);
            if (dist <= -delta) {
                var normal = Vector2.zero;
                @field(normal, axis) = 1;
                Contact.record(&best, .{
                    .fraction = if (dist <= 0) 0 else dist / -delta,
                    .normal = normal,
                    .rectPair = isRect,
                });
            }
        } else if (delta > 0) {
            const dist = @field(max, axis) - @field(boxMax, axis);
            if (dist <= delta) {
                var normal = Vector2.zero;
                @field(normal, axis) = -1;
                Contact.record(&best, .{
                    .fraction = if (dist <= 0) 0 else dist / delta,
                    .normal = normal,
                    .rectPair = isRect,
                });
            }
        }
    }
    return best;
}

/// 扫掠过程中汇总出的最近阻挡接触。
pub const Contact = struct {
    /// 首次阻挡接触占请求位移的比例，范围为 [0, 1]，包含终点接触。
    fraction: f32,
    /// 从障碍朝外的单位法线；同时命中时取最先遇到的。
    normal: Vector2,
    /// 最先记录的接触来自两个轴对齐矩形。
    rectPair: bool = false,
    /// 矩形同时接触的轴向面，各分量为 -1、0 或 1，不是单位向量。
    /// 仅接触矩形角点或圆形时为零，此时使用 normal。
    faces: Vector2 = .zero,

    /// 用单次 Shape.sweep 的命中更新最近接触，并合并同刻轴向面。
    pub fn record(best: *?Contact, hit: math.Hit) void {
        if (best.* == null or hit.fraction < best.*.?.fraction) {
            best.* = .{
                .fraction = hit.fraction,
                .normal = hit.normal,
                .rectPair = hit.rectPair,
            };
        }
        if (hit.rectPair and hit.fraction == best.*.?.fraction) {
            const faces = &best.*.?.faces;
            if (hit.normal.x == 0) faces.y = hit.normal.y;
            if (hit.normal.y == 0) faces.x = hit.normal.x;
        }
    }

    /// 合并另一个已汇总的接触，保留更早的命中并在同刻合并轴向面。
    pub fn merge(best: *?Contact, other: ?Contact) void {
        const found = other orelse return;
        if (best.* == null or found.fraction < best.*.?.fraction) {
            best.* = found;
            return;
        }
        if (found.fraction == best.*.?.fraction) {
            const faces = &best.*.?.faces;
            if (found.faces.x != 0) faces.x = found.faces.x;
            if (found.faces.y != 0) faces.y = found.faces.y;
        }
    }
};

/// 连续 2D 滑墙移动步进器，由调用方在每轮提供本步最近接触。
/// 剩余位移不超过 math.epsilon 时结束；狭缝中连续微小推进视为阻挡，
/// 可能舍弃本帧仍较大的剩余位移，避免反复接触而无法结束。
pub const Slide = struct {
    pub const Step = struct { body: Shape, move: Vector2 };

    body: Shape,
    moved: Vector2 = .zero,
    rem: Vector2,
    prev: ?Vector2 = null,
    stalled: bool = false,

    pub fn init(body: Shape, move: Vector2) Slide {
        return .{ .body = body, .rem = move };
    }

    /// 返回当前待扫掠的形状和剩余位移；剩余位移不超过 math.epsilon 时返回 null。
    pub fn next(self: Slide) ?Step {
        if (self.rem.length2() <= math.epsilon * math.epsilon) return null;
        return .{ .body = self.body.move(self.moved), .move = self.rem };
    }

    /// 根据本轮扫掠的最近接触推进位移，并计算下一轮滑动方向。
    pub fn advance(self: *Slide, contact: ?Contact) void {
        const found = contact orelse {
            self.moved = self.moved.add(self.rem);
            self.rem = .zero;
            return;
        };
        const step = self.rem.scale(found.fraction);
        const small = step.length2() <= math.epsilon * math.epsilon;
        // 首次微小推进仍调整滑动方向并重查，保证贴墙时可以滑动。
        // 连续两次推进都不超过 math.epsilon 时，结束本帧移动。
        if (self.stalled and small) {
            self.rem = .zero;
            return;
        }
        self.moved = self.moved.add(step);
        self.rem = self.rem.scale(1 - found.fraction);
        const hasFaces = found.faces.x != 0 or found.faces.y != 0;
        if (hasFaces or found.rectPair) {
            // 墙面优先。只有孤立矩形角点才用其法线的两个轴。
            const axes = if (hasFaces) found.faces else found.normal;
            if (self.rem.x * axes.x < 0) self.rem.x = 0;
            if (self.rem.y * axes.y < 0) self.rem.y = 0;
            self.prev = null;
        } else {
            self.rem = slideAlong(self.rem, found.normal);
            // 旧法线只约束同一位置上的连续接触。
            if (self.prev) |normal| {
                const inward = self.rem.dot(normal) < -math.epsilon;
                if (found.fraction == 0 and inward) {
                    self.rem = .zero;
                    return;
                }
            }
            self.prev = found.normal;
        }
        self.stalled = small;
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
    /// 结果互不重叠且完整覆盖实心区域，半格等精度由 grid.cellSide 决定。
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
    pub fn slide(self: SolidMask, body: Shape, move: Vector2) Vector2 {
        var s = Slide.init(body, move);
        while (s.next()) |step| s.advance(self.sweep(step.body, step.move));
        return s.moved;
    }

    /// body 沿 move 平移，返回实心瓦片的最早阻挡接触，无命中时返回 null。
    /// 允许沿边滑动和相切；初始重叠时允许朝最近的边界退开。
    /// 网格外不阻挡；只查询接触，不修改形状或计算滑墙位移。
    pub fn sweep(self: SolidMask, body: Shape, move: Vector2) ?Contact {
        var best: ?Contact = null;
        var iter = self.grid.indicesInSweep(body.toRect(), move);
        while (iter.next()) |index| {
            if (!self.bits.isSet(index)) continue;
            const tile = Shape{ .rect = self.grid.indexToRect(index) };
            const found = body.sweep(tile, move) orelse continue;
            Contact.record(&best, found);
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

/// 每格保留首个对象 ID，empty 是不能用于登记的空值。
/// 借用调用方的固定缓冲区，不分配内存；格子下标由 Grid 提供。
pub fn OwnerGrid(comptime Id: type, comptime empty: Id) type {
    return struct {
        ids: []Id,

        const Self = @This();

        /// 清空并借用 ids；长度应为配套 Grid 的 count，存储由调用方管理。
        pub fn init(ids: []Id) Self {
            var self = Self{ .ids = ids };
            self.clear();
            return self;
        }

        pub fn clear(self: *Self) void {
            @memset(self.ids, empty);
        }

        /// 空格写入 id 并返回 null；已占用时返回首个 ID，不覆盖它。
        /// 重复登记同一个 ID 也返回该 ID，共格关系由调用方处理。
        pub fn claim(self: *Self, index: usize, id: Id) ?Id {
            std.debug.assert(id != empty);
            if (self.get(index)) |owner| return owner;
            self.ids[index] = id;
            return null;
        }

        /// 返回指定格子的首个 ID，空格返回 null。
        pub fn get(self: Self, index: usize) ?Id {
            const id = self.ids[index];
            return if (id == empty) null else id;
        }
    };
}

/// 静态网格索引，按格子返回候选矩形下标，并借用建表时的矩形切片提供查询。
pub const StaticIndex = struct {
    grid: Grid,
    rects: []const Rect = &.{},
    offsets: []u32,
    /// 完整分配的编号缓冲区，建表后 offsets 的最后一项表示有效数量。
    ids: []u32,

    /// 按 rects 的下标建立静态网格索引，忽略宽或高为 0 的空矩形。
    /// 同格内按下标升序排列。
    /// 借用 rects 切片而不拥有它；调用方需保证底层内存在索引释放或重建前有效，
    /// 矩形移动、扩大或 rects 扩容重排后需重建索引。
    pub fn build(gpa: Allocator, grid: Grid, rects: []const Rect) !StaticIndex {
        const offsets = try gpa.alloc(u32, grid.count() + 1);
        errdefer gpa.free(offsets);
        @memset(offsets, 0);
        for (rects) |rect| {
            var cells = grid.indicesInRect(rect);
            while (cells.next()) |index| offsets[index] += 1;
        }
        const total = startOffsets(offsets);
        const ids = try gpa.alloc(u32, total);
        for (rects, 0..) |rect, id| {
            fillRectIds(grid, rect, @intCast(id), offsets, ids);
        }
        // 填表后游标是各格的结束位置，右移一项恢复起始位置。
        std.mem.copyBackwards(u32, offsets[1..], offsets[0 .. offsets.len - 1]);
        offsets[0] = 0;
        return .{ .grid = grid, .rects = rects, .offsets = offsets, .ids = ids };
    }

    pub fn deinit(self: *StaticIndex, gpa: Allocator) void {
        gpa.free(self.ids);
        gpa.free(self.offsets);
        self.* = undefined;
    }

    /// 返回指定格子的候选编号，不进行精确相交检测。
    /// 跨格查询可能重复返回同一下标，切片有效期到索引释放为止。
    pub fn idsAt(self: StaticIndex, index: usize) []const u32 {
        return self.ids[self.offsets[index]..self.offsets[index + 1]];
    }

    /// 检查形状是否与索引中的任意有效矩形重叠，相切不算，忽略空矩形。
    pub fn overlaps(self: StaticIndex, body: Shape) bool {
        var iter = self.grid.indicesInRect(body.toRect());
        while (iter.next()) |index| {
            for (self.idsAt(index)) |id| {
                if (overlapsRect(body, self.rects[id])) return true;
            }
        }
        return false;
    }

    /// body 沿 move 平移，返回索引中有效矩形的最早阻挡接触，无命中返回 null。
    pub fn sweep(self: StaticIndex, body: Shape, move: Vector2) ?Contact {
        var best: ?Contact = null;
        var iter = self.grid.indicesInSweep(body.toRect(), move);
        while (iter.next()) |index| {
            for (self.idsAt(index)) |id| {
                const rect = self.rects[id];
                if (rect.size.x <= 0 or rect.size.y <= 0) continue;
                const found = body.sweep(.{ .rect = rect }, move) orelse continue;
                Contact.record(&best, found);
            }
        }
        return best;
    }

    /// 按索引中的有效矩形做连续 2D 滑墙移动，返回实际位移。
    pub fn slide(self: StaticIndex, body: Shape, move: Vector2) Vector2 {
        var s = Slide.init(body, move);
        while (s.next()) |step| s.advance(self.sweep(step.body, step.move));
        return s.moved;
    }
};

/// 按需组合静态瓦片位图、矩形索引和活动边界，借用索引中的矩形数据。
pub const Static = struct {
    mask: ?SolidMask = null,
    index: ?StaticIndex = null,
    bounds: ?Rect = null,

    /// 释放位图和索引缓冲区，保留借用的矩形数据，并重置为空。
    pub fn deinit(self: *Static, gpa: Allocator) void {
        if (self.index) |*index| index.deinit(gpa);
        if (self.mask) |*mask| mask.deinit(gpa);
        self.* = .{};
    }

    /// 设置 rect 覆盖到的整格，按网格边界裁剪；要求 mask 存在。
    pub fn setCellsInRect(self: *Static, rect: Rect) void {
        self.mask.?.setCellsInRect(rect, true);
    }

    pub fn overlaps(self: Static, body: Shape) bool {
        if (self.bounds) |bounds| {
            if (!bounds.containsRect(body.toRect())) return true;
        }
        if (self.mask) |mask| if (mask.overlaps(body)) return true;
        if (self.index) |index| if (index.overlaps(body)) return true;
        return false;
    }

    pub fn sweep(self: Static, body: Shape, move: Vector2) ?Contact {
        var best: ?Contact = null;
        if (self.mask) |mask| {
            Contact.merge(&best, mask.sweep(body, move));
        }
        if (self.index) |index| {
            Contact.merge(&best, index.sweep(body, move));
        }
        if (self.bounds) |bounds| {
            Contact.merge(&best, sweepBounds(bounds, body, move));
        }
        return best;
    }

    pub fn slide(self: Static, body: Shape, move: Vector2) Vector2 {
        var s = Slide.init(body, move);
        while (s.next()) |step| s.advance(self.sweep(step.body, step.move));
        return s.moved;
    }
};

/// 按 clear、countRect、prepare、add、finish 的顺序重建网格索引。
/// 两遍遍历须提供相同的矩形；不保存矩形，各次调用使用同一分配器。
pub const DynamicIndex = struct {
    index: StaticIndex,
    phase: Phase = .counting,

    const Phase = enum { counting, filling, ready };

    /// 为固定网格分配偏移表，初始即可计数；空表也需 prepare、finish 后查询。
    pub fn init(gpa: Allocator, grid: Grid) !DynamicIndex {
        const offsets = try gpa.alloc(u32, grid.count() + 1);
        @memset(offsets, 0);
        return .{ .index = .{ .grid = grid, .offsets = offsets, .ids = &.{} } };
    }

    pub fn deinit(self: *DynamicIndex, gpa: Allocator) void {
        self.index.deinit(gpa);
        self.* = undefined;
    }

    /// 开始新一轮，清空计数和查询结果，保留编号容量。
    pub fn clear(self: *DynamicIndex) void {
        @memset(self.index.offsets, 0);
        self.phase = .counting;
    }

    /// 第一遍只统计每格数量。宽高非负，空矩形忽略，范围按网格裁剪。
    pub fn countRect(self: *DynamicIndex, rect: Rect) void {
        std.debug.assert(self.phase == .counting);
        var cells = self.index.grid.indicesInRect(rect);
        while (cells.next()) |index| self.index.offsets[index] += 1;
    }

    /// 计数完成后准备填表空间，仅容量不足时扩容，每轮成功调用一次。
    /// 失败时保留计数和已有容量，可以直接重试，但不能查询。
    pub fn prepare(self: *DynamicIndex, gpa: Allocator) !void {
        std.debug.assert(self.phase == .counting);
        const index = &self.index;
        var total: u32 = 0;
        for (index.offsets) |count| total += count;
        if (total > index.ids.len) {
            var ids = std.ArrayList(u32).fromOwnedSlice(index.ids);
            ids.items.len = 0;
            try ids.ensureTotalCapacity(gpa, total);
            index.ids = ids.allocatedSlice();
        }
        _ = startOffsets(index.offsets);
        self.phase = .filling;
    }

    /// prepare 成功后进行第二遍登记，直接写入调用方 ID，不分配内存。
    pub fn add(self: *DynamicIndex, id: u32, rect: Rect) void {
        std.debug.assert(self.phase == .filling);
        fillRectIds(self.index.grid, rect, id, self.index.offsets, self.index.ids);
    }

    /// 全部 ID 填入后结束本轮构建，此后才能查询。
    pub fn finish(self: *DynamicIndex) void {
        std.debug.assert(self.phase == .filling);
        const offsets = self.index.offsets;
        // 填表后游标是各格的结束位置，右移一项恢复起始位置。
        std.mem.copyBackwards(u32, offsets[1..], offsets[0 .. offsets.len - 1]);
        offsets[0] = 0;
        self.phase = .ready;
    }

    /// 仅在 finish 后查询，按 add 顺序返回候选 ID，不做精确检测。
    /// 跨格或重复登记可能返回重复 ID；下次 clear 或释放后切片失效。
    pub fn idsAt(self: DynamicIndex, index: usize) []const u32 {
        std.debug.assert(self.phase == .ready);
        return self.index.idsAt(index);
    }
};

// 将每格数量变成起始位置，最后一项保存编号总数。
fn startOffsets(offsets: []u32) u32 {
    var total: u32 = 0;
    for (offsets) |*offset| {
        const count = offset.*;
        offset.* = total;
        total += count;
    }
    return total;
}

fn overlapsRect(body: Shape, rect: Rect) bool {
    if (rect.size.x <= 0 or rect.size.y <= 0) return false;
    return switch (body) {
        .rect => |r| r.intersect(rect),
        .circle => |c| c.separate(rect) != null,
    };
}

fn fillRectIds(grid: Grid, rect: Rect, id: u32, offsets: []u32, ids: []u32) void {
    var cells = grid.indicesInRect(rect);
    while (cells.next()) |index| {
        ids[offsets[index]] = id;
        offsets[index] += 1;
    }
}
