const std = @import("std");

pub const epsilon = 1e-4;

pub const Timer = struct {
    duration: f32,
    elapsed: f32 = 0,

    pub fn init(duration: f32) Timer {
        return Timer{ .duration = duration };
    }

    pub fn initFinished(duration: f32) Timer {
        return Timer{ .duration = duration, .elapsed = duration };
    }

    pub fn update(self: *Timer, delta: f32) void {
        if (self.elapsed < self.duration) self.elapsed += delta;
    }

    pub fn updateRunning(self: *Timer, delta: f32) bool {
        self.update(delta);
        return self.isRunning();
    }

    pub fn updateFinished(self: *Timer, delta: f32) bool {
        self.update(delta);
        return !self.isRunning();
    }

    pub fn updateLooped(self: *Timer, delta: f32) bool {
        self.elapsed += delta;
        if (self.elapsed < self.duration) return false;
        self.elapsed -= self.duration;
        return true;
    }

    pub fn isRunning(self: *const Timer) bool {
        return self.elapsed < self.duration;
    }

    pub fn stepIndex(self: *const Timer, step: f32) usize {
        return @intFromFloat(@trunc(self.elapsed / step));
    }

    pub fn isEvenStep(self: *const Timer, step: f32) bool {
        return self.stepIndex(step) & 1 == 0;
    }

    pub fn progress(self: *const Timer) f32 {
        return @min(self.elapsed / self.duration, 1);
    }

    pub fn restart(self: *Timer) void {
        self.elapsed = 0;
    }

    pub fn stop(self: *Timer) void {
        self.elapsed = self.duration;
    }
};

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

pub fn toIndex(T: type, value: anytype) T {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@intFromEnum(value)),
        .int, .comptime_int => @intCast(value),
        else => @compileError("index must be enum or int"),
    };
}

pub const enums = struct {
    const Array = std.EnumArray;

    pub fn len(comptime E: type) usize {
        return std.meta.fields(E).len;
    }

    pub fn inRange(e: anytype, min: @TypeOf(e), max: @TypeOf(e)) bool {
        const v = @intFromEnum(e);
        return v >= @intFromEnum(min) and v <= @intFromEnum(max);
    }

    pub fn next(value: anytype) @TypeOf(value) {
        const values = std.enums.values(@TypeOf(value));
        for (values, 0..) |item, i| {
            if (item == value) return values[(i + 1) % values.len];
        }
        unreachable;
    }

    pub fn to(E: type, value: anytype) E {
        const T = @TypeOf(value);
        if (T == []const u8) return std.meta.stringToEnum(E, value).?;
        return @enumFromInt(value);
    }

    pub fn array(E: type, V: type, values: []const V) Array(E, V) {
        const keys = std.enums.values(E);
        var result: Array(E, V) = .initUndefined();
        for (keys, values) |key, value| result.set(key, value);
        return result;
    }

    fn EntryArray(T: type) type {
        return Array(@FieldType(T, "type"), @FieldType(T, "value"));
    }
    pub fn fromEntries(Entry: type, slice: anytype) EntryArray(Entry) {
        var result: EntryArray(Entry) = .initUndefined();
        for (slice) |value| result.set(value.type, value.value);
        return result;
    }
};

pub const Vector = Vector2;
pub const Vector2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero = Vector2{ .x = 0, .y = 0 };
    pub const center = Vector2{ .x = 0.5, .y = 0.5 };
    pub const one = Vector2{ .x = 1, .y = 1 };

    pub fn xy(x: f32, y: f32) Vector2 {
        return .{ .x = x, .y = y };
    }

    pub fn square(size: f32) Vector2 {
        return .{ .x = size, .y = size };
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

pub const Rect = struct {
    min: Vector2 = .zero,
    size: Vector2 = .one,

    pub fn init(position: Vector2, sizeV: Vector2) Rect {
        return Rect{ .min = position, .size = sizeV };
    }

    pub fn rect(position: Vector2, sizeV: Vector2) Rect {
        return Rect{ .min = position, .size = sizeV };
    }

    pub fn fromMax(minV: Vector2, maxV: Vector2) Rect {
        return Rect{ .min = minV, .size = maxV.sub(minV) };
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

    /// 返回重叠区域
    pub fn overlapArea(self: Rect, other: Rect) Rect {
        const overlapMin = self.min.max(other.min);
        const overlapMax = self.max().min(other.max());
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
        const size = Vector2.square(self.radius * 2);
        return .init(self.center.sub(.square(self.radius)), size);
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
    // capsule: AxisCapsule,

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

    pub fn intersect(self: Shape, other: anytype) bool {
        const isShape = (@TypeOf(other) == Shape);
        return switch (self) {
            inline else => |a| if (isShape) switch (other) {
                inline else => |b| a.intersect(b),
            } else a.intersect(other),
        };
    }
};

pub const random = struct {
    var prng: std.Random.DefaultPrng = undefined;

    pub fn init(seed: u64) void {
        prng = .init(seed);
    }

    fn get() std.Random {
        return prng.random();
    }

    pub fn float(min: f32, max: f32) f32 {
        return get().float(f32) * (max - min) + min;
    }

    pub fn int(T: type, min: T, max: T) T {
        return get().intRangeLessThan(T, min, max);
    }

    pub fn intBiased(T: type, min: T, max: T) T {
        return get().intRangeLessThanBiased(T, min, max);
    }

    pub fn intMost(T: type, min: T, max: T) T {
        return get().intRangeAtMost(T, min, max);
    }

    pub fn intMostBiased(T: type, min: T, max: T) T {
        return get().intRangeAtMostBiased(T, min, max);
    }

    pub fn enumValue(comptime EnumType: type) EnumType {
        return get().enumValue(EnumType);
    }

    pub fn boolean() bool {
        return get().boolean();
    }
};
