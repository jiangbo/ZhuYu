const std = @import("std");
pub const sokol = @import("sokol");

pub const imgui = sokol.imgui;

pub const window = @import("window.zig");
pub const assets = @import("assets.zig");
pub const audio = @import("audio.zig");
pub const graphics = @import("graphics.zig");
pub const batch = @import("batch.zig");
pub const camera = @import("camera.zig");
pub const text = @import("text.zig");
const core = @import("internal/core.zig");
const platform = @import("internal/platform.zig");

pub const key = window.key;
pub const mouse = window.mouse;

pub const extend = struct {
    pub const debug = @import("extend/debug.zig");
    pub const widget = @import("extend/widget.zig");
    pub const bag = @import("extend/bag.zig");
    pub const storage = @import("extend/storage.zig");
    pub const touch = @import("extend/touch.zig");
    pub const tiled = @import("extend/tiled.zig");
};

// 常用扩展模块，保留 extend 下的完整分类。
pub const widget = extend.widget;
pub const storage = extend.storage;

pub const Image = graphics.Image;
pub const Vertex = graphics.Vertex;
pub const NineImage = graphics.NineImage;
pub const Atlas = graphics.Atlas;
pub const Color = graphics.Color;
pub const Animation = graphics.Animation;
pub const Allocator = std.mem.Allocator;

pub const Timer = core.Timer;
pub const DateTime = platform.DateTime;
pub const ease = core.ease;
pub const enums = core.enums;
pub const Vector = core.Vector;
pub const Vector2 = core.Vector2;
pub const Vector3 = core.Vector3;
pub const Vector4 = core.Vector4;
pub const Rect = core.Rect;
pub const Circle = core.Circle;
pub const AxisCapsule = core.AxisCapsule;
pub const Shape = core.Shape;
pub const random = core.random;

// 安卓平台适配，日志和 panic 配置由 buildAndroid 注入入口。
pub const android = struct {
    pub const log = @import("internal/android.zig").log;
    pub const panic = @import("internal/android.zig").panic;
};

pub const epsilon = core.epsilon;

pub const clamp = std.math.clamp;
pub const loadImage = assets.loadImage;
pub const loadAtlas = assets.atlas.load;
pub const getImage = assets.getImageByPath;
pub const localTime = platform.localTime;
pub const oom = core.oom;

/// 获取当前 Unix 时间戳；需要先调用 zhu.setup。
pub fn timestamp() std.Io.Timestamp {
    return std.Io.Timestamp.now(assets.io, .real);
}

/// 获取当前本地日期和时间；需要先调用 zhu.setup。
pub fn now() DateTime {
    return localTime(timestamp());
}

// 按内存布局重新解释值，调用方保证字段布局相符。
pub fn reinterpret(comptime T: type, value: anytype) T {
    const Value = @TypeOf(value);
    if (@sizeOf(T) != @sizeOf(Value)) {
        @compileError("types must have the same size");
    }
    // 本地副本满足两种类型的对齐，转换后返回值而非指针。
    const source: Value align(@max(@alignOf(T), @alignOf(Value))) = value;
    return @as(*const T, @ptrCast(&source)).*;
}

// 按小端字节序读取整数。
pub fn readInt(comptime T: type, bytes: anytype) T {
    return std.mem.readInt(T, bytes, .little);
}

// 格式化到缓冲区，空间不足时直接终止。
pub fn format(buf: []u8, comptime fmt: []const u8, args: anytype) []u8 {
    return std.mem.print(buf, fmt, args) catch @panic("buffer too small");
}

// 格式化为以零结尾的字符串，缓冲区不足时直接终止。
pub fn formatZ(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]u8 {
    return std.mem.printSentinel(buf, fmt, args, 0) catch
        @panic("buffer too small");
}

pub const SetupOption = struct {
    storage: ?[]const u8 = null, // 应用数据名称；为空时不初始化存档。
};

/// 配置引擎依赖；指定 storage 时同时初始化用户数据存储。
pub fn setup(info: std.process.Init, option: SetupOption) void {
    platform.setup();
    const gpa = assets.setup(info.io, info.gpa);
    window.setup(gpa);
    if (option.storage) |name| extend.storage.setup(info, gpa, name);
}

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
        .@"enum" => @intCast(@backingInt(value)),
        .int, .comptime_int => @intCast(value),
        else => @compileError("index must be enum or int"),
    };
}

// 验证运行时整数到窄枚举的转换，避免只编译声明漏掉泛型错误。
test "enum accepts runtime integer" {
    const Kind = enum(u8) { first, second };
    var value: u32 = 1;
    _ = &value;
    try std.testing.expectEqual(Kind.second, enums.to(Kind, value));
    try std.testing.expectEqual(@as(usize, 2), enums.len(Kind));
}

test "compile zhu modules" {
    // 测试入口没有应用 frame，窗口启动路径由 clear 示例构建验证。
    inline for (comptime std.meta.declarations(window)) |name| {
        if (!comptime std.mem.eql(u8, name, "run")) _ = &@field(window, name);
    }
    std.testing.refAllDecls(assets);
    std.testing.refAllDecls(audio);
    std.testing.refAllDecls(graphics);
    std.testing.refAllDecls(batch);
    std.testing.refAllDecls(camera);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(extend.debug);
    std.testing.refAllDecls(extend.widget);
    std.testing.refAllDecls(extend.bag);
    std.testing.refAllDecls(extend.storage);
    std.testing.refAllDecls(extend.touch);
    std.testing.refAllDecls(extend.touch.stick);
    std.testing.refAllDecls(extend.tiled);
}
