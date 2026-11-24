//! 引擎共用的内存、计时、枚举与随机数工具。
const std = @import("std");

pub fn oom() noreturn {
    @panic("out of memory");
}

pub const Counter = struct {
    child: std.mem.Allocator,
    // 各项独立统计，不要求读取时属于同一个瞬间。
    used: std.atomic.Value(usize) = .init(0),
    max: std.atomic.Value(usize) = .init(0),
    count: std.atomic.Value(usize) = .init(0),

    pub fn init(child: std.mem.Allocator) Counter {
        return .{ .child = child };
    }

    pub fn allocator(self: *Counter) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = @This().alloc,
                .resize = resize,
                .remap = remap,
                .free = frees,
            },
        };
    }

    const A = std.mem.Alignment;
    fn alloc(ctx: *anyopaque, len: usize, a: A, r: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, r) orelse return null;
        _ = self.count.fetchAdd(1, .monotonic);
        const used = self.used.fetchAdd(len, .monotonic) + len;
        if (used > self.max.load(.monotonic)) {
            _ = self.max.fetchMax(used, .monotonic);
        }
        return p;
    }

    fn resize(ctx: *anyopaque, b: []u8, a: A, len: usize, r: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const stable = self.child.rawResize(b, a, len, r);
        if (stable) {
            _ = self.count.fetchAdd(1, .monotonic);
            if (len > b.len) {
                const growth = len - b.len;
                const used = self.used.fetchAdd(growth, .monotonic) + growth;
                if (used > self.max.load(.monotonic)) {
                    _ = self.max.fetchMax(used, .monotonic);
                }
            } else {
                _ = self.used.fetchSub(b.len - len, .monotonic);
            }
        }
        return stable;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: A, len: usize, r: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const n = self.child.rawRemap(m, a, len, r) orelse return null;
        _ = self.count.fetchAdd(1, .monotonic);
        if (len > m.len) {
            const growth = len - m.len;
            const used = self.used.fetchAdd(growth, .monotonic) + growth;
            if (used > self.max.load(.monotonic)) {
                _ = self.max.fetchMax(used, .monotonic);
            }
        } else {
            _ = self.used.fetchSub(m.len - len, .monotonic);
        }
        return n;
    }

    fn frees(ctx: *anyopaque, buf: []u8, a: A, r: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        _ = self.used.fetchSub(buf.len, .monotonic);
        return self.child.rawFree(buf, a, r);
    }
};

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

pub const enums = struct {
    const Array = std.EnumArray;

    /// 以枚举名作为字段名，每个字段都必须显式赋值。
    pub fn FieldStruct(E: type, V: type) type {
        return std.enums.EnumFieldStruct(E, V, null);
    }

    // 根据配置字段生成连续枚举。
    pub fn fromField(items: anytype, comptime field: []const u8) type {
        const Tag = std.math.IntFittingRange(0, items.len - 1);
        var names: [items.len][]const u8 = undefined;
        var values: [items.len]Tag = undefined;

        for (items, 0..) |item, index| {
            const value = @field(item, field);
            const isLiteral = @typeInfo(@TypeOf(value)) == .enum_literal;
            names[index] = if (isLiteral) @tagName(value) else value;
            values[index] = index;
        }

        return @Enum(Tag, .exhaustive, &names, &values);
    }

    pub fn len(comptime E: type) usize {
        return @typeInfo(E).@"enum".field_names.len;
    }

    pub fn inRange(e: anytype, min: @TypeOf(e), max: @TypeOf(e)) bool {
        const v = @backingInt(e);
        return v >= @backingInt(min) and v <= @backingInt(max);
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
        return @fromBackingInt(@intCast(value));
    }

    fn EntryArray(T: type) type {
        return Array(@FieldType(T, "type"), @FieldType(T, "value"));
    }
    pub fn fromEntries(Entry: type, slice: anytype) EntryArray(Entry) {
        var result: EntryArray(Entry) = .initUndefined();
        for (slice) |value| result.set(value.type, value.value);
        return result;
    }

    /// 按 V 的枚举字段 key 构造数组。每个键必须配置一次。
    pub fn array(
        V: type,
        comptime key: []const u8,
        comptime list: []const V,
    ) Array(@FieldType(V, key), V) {
        const E = @FieldType(V, key);
        return comptime blk: {
            const print = std.fmt.comptimePrint;
            var result: Array(E, V) = .initUndefined();
            var missing: std.EnumSet(E) = .full;
            for (list) |value| {
                const tag = @field(value, key);
                if (!missing.contains(tag))
                    @compileError(print("duplicate key {any}", .{tag}));
                missing.remove(tag);
                result.set(tag, value);
            }
            var keys = missing.iterator();
            if (keys.next()) |tag| @compileError(print("missing key {any}", .{tag}));
            break :blk result;
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
