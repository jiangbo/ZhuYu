const std = @import("std");
pub const sokol = @import("sokol");

pub const imgui = sokol.imgui;

pub const window = @import("window.zig");
pub const assets = @import("assets.zig");
pub const audio = @import("audio.zig");
pub const graphics = @import("graphics.zig");
pub const batch = @import("batch.zig");
pub const camera = @import("camera.zig");
pub const math = @import("math.zig");
pub const text = @import("text.zig");
pub const codec = @import("internal/codec.zig");
pub const storage = platform.storage;
const core = @import("internal/core.zig");
const platform = @import("internal/platform.zig");

pub const key = window.key;
pub const mouse = window.mouse;
pub const action = window.action;

pub const music = struct {
    pub const State = audio.MusicState;
    pub const Option = audio.MusicOption;
    pub const play = audio.playMusic;
    pub const playOption = audio.playMusicOption;
    pub const pause = audio.pauseMusic;
    pub const unpause = audio.resumeMusic;
    pub const @"resume" = audio.resumeMusic;
    pub const stop = audio.stopMusic;
    pub const getState = audio.getMusicState;
    pub const getVolume = audio.getMusicVolume;
    pub const setVolume = audio.setMusicVolume;
    pub const changeVolume = audio.changeMusicVolume;
};

pub const sound = struct {
    pub const Option = audio.Sound.Option;
    pub const play = audio.playSound;
    pub const playOption = audio.playSoundOption;
    pub const stopAll = audio.stopSounds;
    pub const getVolume = audio.getSoundVolume;
    pub const setVolume = audio.setSoundVolume;
    pub const changeVolume = audio.changeSoundVolume;
};

pub const extend = struct {
    pub const debug = @import("extend/debug.zig");
    pub const widget = @import("extend/widget.zig");
    pub const bag = @import("extend/bag.zig");
    pub const touch = @import("extend/touch.zig");
    pub const spatial = @import("extend/spatial.zig");
    pub const tiled = @import("extend/tiled.zig");
};

// 常用扩展模块，保留 extend 下的完整分类。
pub const widget = extend.widget;

pub const Image = graphics.Image;
pub const Vertex = graphics.Vertex;
pub const NineImage = graphics.NineImage;
pub const Atlas = graphics.Atlas;
pub const Color = graphics.Color;
pub const Animation = graphics.Animation;

pub const Timer = core.Timer;
pub const DateTime = platform.DateTime;
pub const ease = math.ease;
pub const enums = core.enums;
pub const Vector = math.Vector;
pub const Vector2 = math.Vector2;
pub const Vector3 = math.Vector3;
pub const Vector4 = math.Vector4;
pub const Rect = math.Rect;
pub const Circle = math.Circle;
pub const AxisCapsule = math.AxisCapsule;
pub const Shape = math.Shape;
pub const random = core.random;
pub const dateTimeBufferSize = platform.dateTimeBufferSize;

// 安卓平台适配，日志和 panic 配置由 buildAndroid 注入入口。
pub const android = struct {
    pub const log = @import("internal/android.zig").log;
    pub const panic = @import("internal/android.zig").panic;
};

pub const epsilon = math.epsilon;

pub const clamp = math.clamp;
pub const percentInt = math.percentInt;
pub const sinInt = math.sinInt;
pub const ceilAway = math.ceilAway;
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
    const gpa = assets.setup(info.io, info.gpa);
    platform.setup(info, gpa, option.storage);
    window.setup(gpa);
}

pub fn toIndex(T: type, value: anytype) T {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@backingInt(value)),
        .int, .comptime_int => @intCast(value),
        else => @compileError("index must be enum or int"),
    };
}

test "compile zhu modules" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(assets);
    std.testing.refAllDecls(audio);
    std.testing.refAllDecls(graphics);
    std.testing.refAllDecls(batch);
    std.testing.refAllDecls(camera);
    std.testing.refAllDecls(math);
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(extend.debug);
    std.testing.refAllDecls(extend.widget);
    std.testing.refAllDecls(extend.bag);
    std.testing.refAllDecls(storage);
    std.testing.refAllDecls(extend.touch);
    std.testing.refAllDecls(extend.touch.stick);
    std.testing.refAllDecls(extend.spatial);
    std.testing.refAllDecls(extend.tiled);
}
