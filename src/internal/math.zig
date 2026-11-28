//! 数学函数、缓动、向量与几何形状。
const std = @import("std");

pub const clamp = std.math.clamp;

pub fn percentInt(a: anytype, b: anytype) f32 {
    const aa: f32 = @floatFromInt(a);
    return aa / @as(f32, @floatFromInt(b));
}

pub fn sinInt(T: type, angle: f32, min: T, max: T) T {
    const minF: f32 = @floatFromInt(min);
    const maxF: f32 = @floatFromInt(max);
    const half = (maxF - minF) * 0.5;
    const result = minF + half + @sin(angle) * half;
    return @intFromFloat(@round(result));
}

pub fn ceilAway(value: f32) f32 {
    return if (value > 0) @ceil(value) else @floor(value);
}

/// 缓动进度，输入 t 为 0～1；back 系列允许输出超出此范围。
/// In 由慢到快，Out 由快到慢，InOut 两端慢、中间快。
pub const ease = struct {
    pub fn smoothstep(t: f32) f32 {
        return t * t * (3 - 2 * t);
    }

    pub fn quadIn(t: f32) f32 {
        return t * t;
    }

    pub fn quadOut(t: f32) f32 {
        return 1 - quadIn(1 - t);
    }

    pub fn quadInOut(t: f32) f32 {
        return if (t < 0.5) quadIn(2 * t) * 0.5 else 1 - quadIn(2 - 2 * t) * 0.5;
    }

    pub fn cubeIn(t: f32) f32 {
        return t * t * t;
    }

    pub fn cubeOut(t: f32) f32 {
        return 1 - cubeIn(1 - t);
    }

    pub fn cubeInOut(t: f32) f32 {
        return if (t < 0.5) cubeIn(2 * t) * 0.5 else 1 - cubeIn(2 - 2 * t) * 0.5;
    }

    pub fn quartIn(t: f32) f32 {
        const square = t * t;
        return square * square;
    }

    pub fn quartOut(t: f32) f32 {
        return 1 - quartIn(1 - t);
    }

    pub fn quartInOut(t: f32) f32 {
        return if (t < 0.5) quartIn(2 * t) * 0.5 else 1 - quartIn(2 - 2 * t) * 0.5;
    }

    pub fn quintIn(t: f32) f32 {
        const square = t * t;
        return square * square * t;
    }

    pub fn quintOut(t: f32) f32 {
        return 1 - quintIn(1 - t);
    }

    pub fn quintInOut(t: f32) f32 {
        return if (t < 0.5) quintIn(2 * t) * 0.5 else 1 - quintIn(2 - 2 * t) * 0.5;
    }

    pub fn sinIn(t: f32) f32 {
        return 1 - @cos(t * (std.math.pi / 2.0));
    }

    pub fn sinOut(t: f32) f32 {
        return @sin(t * (std.math.pi / 2.0));
    }

    pub fn sinInOut(t: f32) f32 {
        return (1 - @cos(t * std.math.pi)) * 0.5;
    }

    pub fn circleIn(t: f32) f32 {
        return 1 - @sqrt(1 - t * t);
    }

    pub fn circleOut(t: f32) f32 {
        return @sqrt(t * (2 - t));
    }

    pub fn circleInOut(t: f32) f32 {
        return if (t < 0.5) circleIn(2 * t) * 0.5 else 1 - circleIn(2 - 2 * t) * 0.5;
    }

    pub fn backIn(t: f32) f32 {
        return t * t * t - t * @sin(t * std.math.pi);
    }

    pub fn backOut(t: f32) f32 {
        return 1 - backIn(1 - t);
    }

    pub fn backInOut(t: f32) f32 {
        return if (t < 0.5) backIn(2 * t) * 0.5 else 1 - backIn(2 - 2 * t) * 0.5;
    }
};

pub const epsilon = 1e-4;

pub const Vector = Vector2;
pub const Vector2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero = Vector2{ .x = 0, .y = 0 };
    pub const center = Vector2{ .x = 0.5, .y = 0.5 };
    pub const one = Vector2{ .x = 1, .y = 1 };
    pub const inf = Vector2.all(std.math.inf(f32));

    pub fn xy(x: f32, y: f32) Vector2 {
        return .{ .x = x, .y = y };
    }

    pub fn all(value: f32) Vector2 {
        return .{ .x = value, .y = value };
    }

    pub fn toVector3(self: Vector2, z: f32) Vector3 {
        return .{ .x = self.x, .y = self.y, .z = z };
    }

    pub fn add(self: Vector2, other: Vector2) Vector2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn addX(self: Vector2, x: f32) Vector2 {
        return .{ .x = self.x + x, .y = self.y };
    }

    pub fn addY(self: Vector2, y: f32) Vector2 {
        return .{ .x = self.x, .y = self.y + y };
    }

    pub fn addXY(self: Vector2, x: f32, y: f32) Vector2 {
        return .{ .x = self.x + x, .y = self.y + y };
    }

    pub fn sub(self: Vector2, other: Vector2) Vector2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn mul(self: Vector2, other: Vector2) Vector2 {
        return .{ .x = self.x * other.x, .y = self.y * other.y };
    }

    pub fn div(self: Vector2, other: Vector2) Vector2 {
        return .{ .x = self.x / other.x, .y = self.y / other.y };
    }

    pub fn scale(self: Vector2, scalar: f32) Vector2 {
        return .{ .x = self.x * scalar, .y = self.y * scalar };
    }

    pub fn neg(self: Vector2) Vector2 {
        return .{ .x = -self.x, .y = -self.y };
    }

    /// 返回长度，如果不是真正需要长度，考虑使用 length2，避免开方
    pub fn length(self: Vector2) f32 {
        return std.math.sqrt(self.x * self.x + self.y * self.y);
    }

    /// 返回长度的平方，比 length 性能更好，避免开方
    pub fn length2(self: Vector2) f32 {
        return self.x * self.x + self.y * self.y;
    }

    pub fn dot(self: Vector2, other: Vector2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn abs(self: Vector2) Vector2 {
        return .{ .x = @abs(self.x), .y = @abs(self.y) };
    }

    pub fn normalize(self: Vector2) Vector2 {
        return self.scale(1 / self.length());
    }

    pub fn sign(self: Vector2) Vector2 {
        return .{ .x = std.math.sign(self.x), .y = std.math.sign(self.y) };
    }

    pub fn ceil(self: Vector2) Vector2 {
        return .{ .x = @ceil(self.x), .y = @ceil(self.y) };
    }

    pub fn round(self: Vector2) Vector2 {
        return .{ .x = @round(self.x), .y = @round(self.y) };
    }

    pub fn floor(self: Vector2) Vector2 {
        return .{ .x = @floor(self.x), .y = @floor(self.y) };
    }

    pub fn clamp(self: Vector2, minV: Vector2, maxV: Vector2) Vector2 {
        return .{
            .x = std.math.clamp(self.x, minV.x, maxV.x),
            .y = std.math.clamp(self.y, minV.y, maxV.y),
        };
    }

    pub fn max(self: Vector2, other: Vector2) Vector2 {
        return .{
            .x = @max(self.x, other.x),
            .y = @max(self.y, other.y),
        };
    }

    pub fn maxAxis(self: Vector2) f32 {
        return @max(self.x, self.y);
    }

    pub fn min(self: Vector2, other: Vector2) Vector2 {
        return .{
            .x = @min(self.x, other.x),
            .y = @min(self.y, other.y),
        };
    }

    pub fn equal(self: Vector2, other: Vector2) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn approxEqual(self: Vector2, other: Vector2) bool {
        return std.math.approxEqAbs(f32, self.x, other.x, epsilon) and
            std.math.approxEqAbs(f32, self.y, other.y, epsilon);
    }

    pub fn approxAbs(self: Vector2, other: Vector2, tolerance: f32) bool {
        return std.math.approxEqAbs(f32, self.x, other.x, tolerance) and
            std.math.approxEqAbs(f32, self.y, other.y, tolerance);
    }

    pub fn atan2(self: Vector2) f32 {
        return std.math.atan2(self.y, self.x);
    }

    pub fn mix(self: Vector2, other: Vector2, t: f32) Vector2 {
        return .{
            .x = std.math.lerp(self.x, other.x, t),
            .y = std.math.lerp(self.y, other.y, t),
        };
    }

    /// 二次贝塞尔：a 为起点，b 为控制点，c 为终点；t 为 0～1。
    pub fn bezier2(a: Vector2, b: Vector2, c: Vector2, t: f32) Vector2 {
        return a.mix(b, t).mix(b.mix(c, t), t);
    }

    /// 三次贝塞尔：a 为起点，b/c 为控制点，d 为终点；t 为 0～1。
    pub fn bezier3(a: Vector2, b: Vector2, c: Vector2, d: Vector2, t: f32) Vector2 {
        return a.mix(b, t).bezier2(b.mix(c, t), c.mix(d, t), t);
    }
};

pub const Vector4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,
    pub const zero = Vector4{ .x = 0, .y = 0, .z = 0, .w = 0 };
    pub const one = Vector4{ .x = 1, .y = 1, .z = 1, .w = 1 };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vector4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn initSize(pos: Vector2, size: Vector2) Vector4 {
        return .{ .x = pos.x, .y = pos.y, .z = size.x, .w = size.y };
    }
};

pub const Vector3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero = Vector3{ .x = 0, .y = 0, .z = 0 };

    pub fn init(x: f32, y: f32) Vector3 {
        return .{ .x = x, .y = y, .z = 1 };
    }
};

pub const Rect = extern struct {
    min: Vector2 = .zero,
    size: Vector2 = .one,

    pub const zero = Rect{ .min = .zero, .size = .zero };

    pub fn init(position: Vector2, sizeV: Vector2) Rect {
        return Rect{ .min = position, .size = sizeV };
    }

    pub fn rect(position: Vector2, sizeV: Vector2) Rect {
        return Rect{ .min = position, .size = sizeV };
    }

    pub fn fromMax(minV: Vector2, maxV: Vector2) Rect {
        return Rect{ .min = minV, .size = maxV.sub(minV) };
    }

    pub fn round(self: Rect) Rect {
        return .init(self.min.round(), self.size.round());
    }

    pub fn max(self: Rect) Vector2 {
        return self.min.add(self.size);
    }

    pub fn move(self: Rect, offset: Vector2) Rect {
        return .{ .min = self.min.add(offset), .size = self.size };
    }

    pub fn center(self: Rect) Vector2 {
        return self.min.add(self.size.scale(0.5));
    }

    pub fn centerScale(self: Rect, scale: f32) Rect {
        const size = self.size.scale(scale);
        const min = self.min.add(self.size.sub(size).scale(0.5));
        return .{ .min = min, .size = size };
    }

    // 将矩形四周向内收缩 padding 像素
    pub fn pad(self: Rect, padding: Vector2) Rect {
        return .{
            .min = self.min.add(padding),
            .size = self.size.sub(padding.scale(2)),
        };
    }

    pub fn contains(self: Rect, other: anytype) bool {
        const T = @TypeOf(other);
        if (T == Vector2) return self.containsPoint(other);
        if (T == Rect) return self.containsRect(other);
        @compileError("unsupported Rect.contains type");
    }

    pub fn containsPoint(self: Rect, point: Vector2) bool {
        return point.x >= self.min.x and point.x <= self.max().x and
            point.y >= self.min.y and point.y <= self.max().y;
    }

    pub fn containsRect(self: Rect, other: Rect) bool {
        const maxS, const maxO = .{ self.max(), other.max() };
        return maxO.x <= maxS.x and maxO.y <= maxS.y and
            other.min.x >= self.min.x and other.min.y >= self.min.y;
    }

    pub fn closestPoint(self: Rect, point: Vector2) Vector2 {
        const maxV = self.max();
        const x = std.math.clamp(point.x, self.min.x, maxV.x);
        const y = std.math.clamp(point.y, self.min.y, maxV.y);
        return .{ .x = x, .y = y };
    }

    /// 返回重叠区域，不相交或仅边缘接触时返回 null。
    pub fn overlapArea(self: Rect, other: Rect) ?Rect {
        const overlapMin = self.min.max(other.min);
        const overlapMax = self.max().min(other.max());
        if (overlapMin.x >= overlapMax.x or overlapMin.y >= overlapMax.y) return null;
        return Rect.fromMax(overlapMin, overlapMax);
    }

    pub fn intersect(self: Rect, other: anytype) bool {
        const T = @TypeOf(other);
        if (T == Rect) return self.intersectRect(other);
        if (T == Circle) return self.intersectCircle(other);
        if (T == AxisCapsule) return self.intersectCapsule(other);
        @compileError("unsupported Rect.intersect type");
    }

    fn intersectRect(self: Rect, other: Rect) bool {
        const maxS, const maxO = .{ self.max(), other.max() };
        return self.min.x < maxO.x and maxS.x > other.min.x and
            self.min.y < maxO.y and maxS.y > other.min.y;
    }

    fn intersectCircle(self: Rect, circle: Circle) bool {
        const closest = self.closestPoint(circle.center);
        return closest.sub(circle.center).length2() <= circle.radius * circle.radius;
    }

    fn intersectCapsule(self: Rect, capsule: AxisCapsule) bool {
        const c1, const r1, const c2 = capsule.parts();
        return self.intersect(r1) or self.intersect(c1) or
            self.intersect(c2);
    }

    /// 返回把 self 推出 other 的最短位移；不重叠或相切时返回 null。
    pub fn separate(self: Rect, other: anytype) ?Vector2 {
        const T = @TypeOf(other);
        if (T == Rect) return self.separateRect(other);
        if (T == Circle) return if (other.separate(self)) |push| push.neg() else null;
        @compileError("unsupported Rect.separate type");
    }

    fn separateRect(self: Rect, other: Rect) ?Vector2 {
        const left = self.max().x - other.min.x;
        const right = other.max().x - self.min.x;
        const up = self.max().y - other.min.y;
        const down = other.max().y - self.min.y;
        if (left <= 0 or right <= 0 or up <= 0 or down <= 0) return null;

        const minX = @min(left, right);
        const minY = @min(up, down);
        if (minX <= minY) return .xy(if (left <= right) -left else right, 0);
        return .xy(0, if (up <= down) -up else down);
    }

    /// 查询从 start 到 start + offset 的线段，起点在形状内或边界上时返回 0。
    pub fn rayCast(self: Rect, start: Vector2, offset: Vector2) ?f32 {
        const end = self.max();
        const hit = castRect(start, offset, self.min, end, true) orelse return null;
        return hit.fraction;
    }

    /// self 沿 offset 平移，other 固定。
    /// 允许沿边滑动和相切。重叠时允许朝最近的边界退开。
    pub fn sweep(self: Rect, other: anytype, offset: Vector2) ?Shape.Hit {
        const T = @TypeOf(other);
        if (T == Rect) {
            // 目标向左上扩张后，只需扫移动矩形的左上角。
            const min = other.min.sub(self.size);
            var hit = castRect(self.min, offset, min, other.max(), false) orelse return null;
            hit.rectPair = true;
            return hit;
        }
        if (T == Circle) {
            // 交换移动方和目标后，位移和返回的法线都反向。
            const hit = other.sweep(self, offset.neg()) orelse return null;
            return .{ .fraction = hit.fraction, .normal = hit.normal.neg() };
        }
        @compileError("unsupported Rect.sweep type");
    }
};

pub const Circle = struct {
    center: Vector2 = .zero,
    radius: f32 = 0,

    pub fn init(center: Vector2, radius: f32) Circle {
        return .{ .center = center, .radius = radius };
    }

    pub fn move(self: Circle, offset: Vector2) Circle {
        return .init(self.center.add(offset), self.radius);
    }

    pub fn toRect(self: Circle) Rect {
        const size = Vector2.all(self.radius * 2);
        return .init(self.center.sub(.all(self.radius)), size);
    }

    pub fn contains(self: Circle, point: Vector2) bool {
        return point.sub(self.center).length2() <= self.radius * self.radius;
    }

    pub fn intersect(self: Circle, other: anytype) bool {
        const T = @TypeOf(other);
        if (T == Rect) return other.intersect(self);
        if (T == Circle) return {
            const radius = self.radius + other.radius;
            const d2 = self.center.sub(other.center).length2();
            return d2 <= radius * radius;
        };
        if (T == AxisCapsule) return other.intersect(self);
        @compileError("unsupported Circle.intersect type");
    }

    /// 返回把 self 推出 other 的最短位移；不重叠或相切时返回 null。
    pub fn separate(self: Circle, other: anytype) ?Vector2 {
        const T = @TypeOf(other);
        if (T == Rect) return self.separateRect(other);
        if (T == Circle) return self.separateCircle(other);
        @compileError("unsupported Circle.separate type");
    }

    fn separateCircle(self: Circle, other: Circle) ?Vector2 {
        const gap = self.center.sub(other.center);
        const sum = self.radius + other.radius;
        const dist2 = gap.length2();
        if (dist2 >= sum * sum) return null;
        if (dist2 == 0) return .xy(sum, 0);

        const dist = @sqrt(dist2);
        return gap.scale((sum - dist) / dist);
    }

    fn separateRect(self: Circle, other: Rect) ?Vector2 {
        const radius = self.radius;
        const closest = other.closestPoint(self.center);
        const gap = self.center.sub(closest);
        const dist2 = gap.length2();
        if (dist2 > 0) {
            if (dist2 >= radius * radius) return null;
            const dist = @sqrt(dist2);
            return gap.scale((radius - dist) / dist);
        }

        // 圆心落在矩形内部或边上，沿最近的边加上半径推出。
        const left = self.center.x - other.min.x;
        const right = other.max().x - self.center.x;
        const up = self.center.y - other.min.y;
        const down = other.max().y - self.center.y;
        const minX = @min(left, right);
        const minY = @min(up, down);
        if (minX <= minY) {
            return .xy(if (left <= right) -(left + radius) else right + radius, 0);
        }
        return .xy(0, if (up <= down) -(up + radius) else down + radius);
    }

    /// 查询从 start 到 start + offset 的线段，起点在形状内或边界上时返回 0。
    pub fn rayCast(self: Circle, start: Vector2, offset: Vector2) ?f32 {
        const hit = castCircle(start, offset, self, true) orelse return null;
        return hit.fraction;
    }

    /// self 沿 offset 平移，other 固定。
    /// 允许沿边滑动和相切。重叠时允许朝最近的边界退开。
    pub fn sweep(self: Circle, other: anytype, offset: Vector2) ?Shape.Hit {
        const T = @TypeOf(other);
        if (T == Rect) return castRoundRect(self, offset, other);
        if (T == Circle) {
            const target = Circle.init(other.center, self.radius + other.radius);
            return castCircle(self.center, offset, target, false);
        }
        @compileError("unsupported Circle.sweep type");
    }
};

pub const AxisCapsule = struct {
    const Parts = struct { Circle, Rect, Circle };
    rect: Rect = .{},

    pub fn init(rect: Rect) AxisCapsule {
        return .{ .rect = rect };
    }

    pub fn move(self: AxisCapsule, offset: Vector2) AxisCapsule {
        return .init(self.rect.move(offset));
    }

    pub fn toRect(self: AxisCapsule) Rect {
        return self.rect;
    }

    pub fn contains(self: AxisCapsule, point: Vector2) bool {
        const c1, const rect, const c2 = self.parts();
        return rect.contains(point) or c1.contains(point) or
            c2.contains(point);
    }

    pub fn intersect(self: AxisCapsule, other: anytype) bool {
        const T = @TypeOf(other);
        if (T == Rect) return other.intersectCapsule(self);
        if (T == Circle) return self.intersectCircle(other);
        if (T == AxisCapsule) return self.intersectCapsule(other);
        @compileError("unsupported AxisCapsule.intersect type");
    }

    fn intersectCircle(self: AxisCapsule, circle: Circle) bool {
        const c1, const rect, const c2 = self.parts();
        return circle.intersect(rect) or circle.intersect(c1) or
            circle.intersect(c2);
    }

    fn intersectCapsule(self: AxisCapsule, other: AxisCapsule) bool {
        const c1, const rect, const c2 = self.parts();
        return other.intersect(rect) or other.intersect(c1) or
            other.intersect(c2);
    }

    fn parts(self: AxisCapsule) Parts {
        const rect = self.rect;
        const radius = @min(rect.size.x, rect.size.y) * 0.5;

        if (rect.size.x >= rect.size.y) {
            const pos = rect.min.addX(radius);
            const rectWidth = rect.size.x - radius * 2;

            return .{
                .init(pos.addY(radius), radius),
                .init(pos, .xy(rectWidth, rect.size.y)),
                .init(pos.addXY(rectWidth, radius), radius),
            };
        }

        const pos = rect.min.addY(radius);
        const rectHeight = rect.size.y - radius * 2;

        return .{
            .init(pos.addX(radius), radius),
            .init(pos, .xy(rect.size.x, rectHeight)),
            .init(pos.addXY(radius, rectHeight), radius),
        };
    }
};

pub const Shape = union(enum) {
    rect: Rect,
    circle: Circle,

    pub const Hit = struct {
        /// 首次接触占请求位移的比例，范围为 [0, 1]。
        fraction: f32,
        /// 从目标表面垂直朝外的单位向量。
        normal: Vector2,
        /// 两个轴对齐矩形之间的接触可按轴约束位移。
        rectPair: bool = false,
    };

    // 返回形状的中心位置。
    pub fn center(self: Shape) Vector2 {
        return switch (self) {
            .rect => |rect| rect.center(),
            .circle => |circle| circle.center,
        };
    }

    pub fn move(self: Shape, offset: Vector2) Shape {
        return switch (self) {
            inline else => |s, tag| @unionInit(Shape, //
                @tagName(tag), s.move(offset)),
        };
    }

    pub fn toRect(self: Shape) Rect {
        return switch (self) {
            .rect => |rect| rect,
            inline else => |shape| shape.toRect(),
        };
    }

    pub fn contains(self: Shape, point: Vector2) bool {
        return switch (self) {
            inline else => |shape| shape.contains(point),
        };
    }

    pub fn intersect(self: Shape, other: Shape) bool {
        return switch (self) {
            inline else => |a| switch (other) {
                inline else => |b| a.intersect(b),
            },
        };
    }

    /// 返回把 self 推出 other 的最短位移；不重叠或相切时返回 null。
    pub fn separate(self: Shape, other: Shape) ?Vector2 {
        return switch (self) {
            inline else => |a| switch (other) {
                inline else => |b| a.separate(b),
            },
        };
    }

    /// 查询从 start 到 start + offset 的线段。
    /// 起点在形状内或边界上时返回 0。
    pub fn rayCast(self: Shape, start: Vector2, offset: Vector2) ?f32 {
        return switch (self) {
            inline else => |shape| shape.rayCast(start, offset),
        };
    }

    /// self 沿 offset 平移，other 固定。
    /// 允许沿边滑动和相切。重叠时允许朝最近的边界退开。
    pub fn sweep(self: Shape, other: Shape, offset: Vector2) ?Hit {
        return switch (self) {
            inline else => |a| switch (other) {
                inline else => |b| a.sweep(b, offset),
            },
        };
    }
};

// 求线段在矩形两轴区间内的共同时间范围。
fn castRect(
    start: Vector2,
    offset: Vector2,
    min: Vector2,
    max: Vector2,
    comptime touch: bool,
) ?Shape.Hit {
    const within = start.x >= min.x and start.x <= max.x and
        start.y >= min.y and start.y <= max.y;
    if (touch and within) return .{ .fraction = 0, .normal = .zero };

    const inside = start.x > min.x and start.x < max.x and
        start.y > min.y and start.y < max.y;
    if (inside) return overlapHit(exitNormal(start, offset, min, max), offset);

    // 点必须同时落在两轴的范围内，所以取两个区间的交集。
    var enter, var exit = .{ -std.math.inf(f64), std.math.inf(f64) };
    var normal = Vector2.zero;
    inline for (.{ "x", "y" }) |axis| check_axis: {
        const origin: f64 = @field(start, axis);
        const delta: f64 = @field(offset, axis);
        const low: f64 = @field(min, axis);
        const high: f64 = @field(max, axis);
        // 这一轴没有位移，只需确认起点在范围内。
        if (delta == 0) {
            if (origin < low or origin > high) return null;
            if (!touch and (origin == low or origin == high)) return null;
            break :check_axis;
        }

        const a = (low - origin) / delta;
        const b = (high - origin) / delta;
        const near = @min(a, b);
        const sign: f32 = if (delta > 0) -1 else 1;
        // 较晚进入的一轴决定接触面，同时进入角点时合成对角法线。
        if (near > enter) {
            enter = near;
            normal = .zero;
            @field(normal, axis) = sign;
        } else if (near == enter) @field(normal, axis) = sign;

        exit = @min(exit, @max(a, b));
    }
    if (enter < 0 or enter > 1 or enter > exit) return null;
    if (!touch and enter == exit) return null;
    if (normal.x != 0 and normal.y != 0) normal = normal.scale(std.math.sqrt1_2);
    return .{ .fraction = @floatCast(enter), .normal = normal };
}

fn castCircle(start: Vector2, offset: Vector2, circle: Circle, touch: bool) ?Shape.Hit {
    const x = @as(f64, start.x) - circle.center.x;
    const y = @as(f64, start.y) - circle.center.y;
    const dx: f64, const dy: f64 = .{ offset.x, offset.y };
    const radius: f64 = circle.radius;
    const distance2 = x * x + y * y;
    const outside = distance2 - radius * radius;
    if (touch and outside <= 0) return .{ .fraction = 0, .normal = .zero };

    const along = x * dx + y * dy;
    if (outside < 0) {
        if (along >= 0) return null;
        const distance = @sqrt(distance2);
        return .{
            .fraction = 0,
            .normal = .xy(@floatCast(x / distance), @floatCast(y / distance)),
        };
    }
    if (along >= 0) return null;

    const length2 = dx * dx + dy * dy;
    const cross = x * dy - y * dx;
    const disc = radius * radius * length2 - cross * cross;
    if (disc < 0 or (!touch and disc == 0)) return null;

    // 用等价的根式，避免起点贴近圆时两项相减丢失精度。
    const fraction = outside / (-along + @sqrt(disc));
    if (fraction > 1) return null;
    const normal: Vector2 = if (radius == 0) .zero else .xy(
        @floatCast((x + dx * fraction) / radius),
        @floatCast((y + dy * fraction) / radius),
    );
    return .{ .fraction = @floatCast(fraction), .normal = normal };
}

fn castRoundRect(circle: Circle, offset: Vector2, rect: Rect) ?Shape.Hit {
    const start = circle.center;
    const min, const max = .{ rect.min, rect.max() };
    const radius = circle.radius;
    if (radius == 0) return castRect(start, offset, min, max, false);

    const gap = start.sub(rect.closestPoint(start));
    const distance2 = gap.length2();
    if (distance2 < radius * radius) {
        const pad = Vector2.all(radius);
        const normal = if (distance2 > 0)
            gap.scale(1 / @sqrt(distance2))
        else
            exitNormal(start, offset, min.sub(pad), max.add(pad));
        return overlapHit(normal, offset);
    }

    // 扩出的圆角矩形是两条矩形带与四个角圆的并集。
    var first = castRect(start, offset, min.addX(-radius), max.addX(radius), false);
    if (castRect(start, offset, min.addY(-radius), max.addY(radius), false)) |hit| {
        if (first == null or hit.fraction < first.?.fraction) first = hit;
    }

    const corners = [_]Vector2{ min, .xy(min.x, max.y), .xy(max.x, min.y), max };
    for (corners) |corner| {
        const cap = Circle.init(corner, radius);
        const hit = castCircle(start, offset, cap, false) orelse continue;
        if (first == null or hit.fraction < first.?.fraction) first = hit;
    }
    const hit = first orelse return null;
    // 按原矩形计算接触法线，矩形带的角点属于圆弧与直边的连接处。
    const point = start.add(offset.scale(hit.fraction));
    const normal = point.sub(rect.closestPoint(point)).normalize();
    return .{ .fraction = hit.fraction, .normal = normal };
}

fn exitNormal(start: Vector2, offset: Vector2, min: Vector2, max: Vector2) Vector2 {
    const low, const high = .{ start.sub(min), max.sub(start) };
    const nearest = @min(low.x, low.y, high.x, high.y);
    // 等距时取和位移最接近的外法线。
    var normal = Vector2.zero;
    var best = -std.math.inf(f32);
    for ([_]f32{ low.x, low.y, high.x, high.y }, [_]Vector2{
        .xy(-1, 0), .xy(0, -1), .xy(1, 0), .xy(0, 1),
    }) |distance, side| {
        const along = offset.dot(side);
        if (distance == nearest and along > best) {
            best = along;
            normal = side;
        }
    }
    return normal;
}

fn overlapHit(normal: Vector2, offset: Vector2) ?Shape.Hit {
    if (offset.dot(normal) >= 0) return null;
    return .{ .fraction = 0, .normal = normal };
}
