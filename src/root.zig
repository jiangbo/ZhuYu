const std = @import("std");
const builtin = @import("builtin");

pub const sokol = @import("sokol");
pub const window = @import("window.zig");
pub const assets = @import("assets.zig");
pub const audio = @import("audio.zig");
pub const graphics = @import("graphics.zig");
pub const batch = @import("batch.zig");
pub const camera = @import("camera.zig");
pub const math = @import("math.zig");
pub const input = @import("input.zig");
pub const text = @import("text.zig");
pub const enums = math.enums;
pub const random = math.random;
pub const key = input.key;
pub const mouse = input.mouse;

pub const extend = struct {
    pub const debug = @import("extend/debug.zig");
    pub const widget = @import("extend/widget.zig");
    pub const bag = @import("extend/bag.zig");
    pub const storage = @import("extend/storage.zig");
    pub const touch = @import("extend/touch.zig");
    pub const tiled = @import("extend/tiled.zig");
};

const memory = @import("internal/memory.zig");

pub const Timer = math.Timer;
pub const Image = graphics.Image;
pub const NineImage = graphics.NineImage;
pub const Atlas = graphics.Atlas;
pub const Vector2 = math.Vector2;
pub const Rect = math.Rect;
pub const Color = graphics.Color;
pub const Animation = graphics.Animation;
pub const EnumAnimation = graphics.EnumAnimation;
pub const Allocator = memory.OomAllocator;

pub const clamp = std.math.clamp;
pub const format = memory.format;
pub const formatZ = memory.formatZ;
pub const getImage = assets.getImageByPath;
pub const oom = memory.oom;
pub const reinterpret = memory.reinterpret;

// 浏览器查询由 web.c 的 EM_JS 提供，保留入口确保静态链接时带入实现。
extern fn zhu_web_keep() void;
extern fn zhu_coarse_pointer() c_int;

/// 初始化内存、窗口 IO 和输入设备推测值。
pub fn init(info: std.process.Init) void {
    memory.init(info.gpa);
    window.io = info.io;
    if (builtin.os.tag == .emscripten) {
        zhu_web_keep();
        // 主要指针为粗略指针时，推测可能没有实体键盘。
        key.mayNotHave = zhu_coarse_pointer() != 0;
    }
}

// 安卓平台适配，日志和 panic 配置由 buildAndroid 注入入口。
pub const android = struct {
    pub const log = @import("internal/android.zig").log;
    pub const panic = @import("internal/android.zig").panic;
};

pub const testing = struct {
    pub const allocator: Allocator = .{ .raw = std.testing.allocator };
};

test "compile zhu modules" {
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(assets);
    std.testing.refAllDecls(audio);
    std.testing.refAllDecls(graphics);
    std.testing.refAllDecls(batch);
    std.testing.refAllDecls(camera);
    std.testing.refAllDecls(math);
    std.testing.refAllDecls(input);
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(extend.debug);
    std.testing.refAllDecls(extend.widget);
    std.testing.refAllDecls(extend.bag);
    std.testing.refAllDecls(extend.storage);
    std.testing.refAllDecls(extend.touch);
    std.testing.refAllDecls(extend.touch.stick);
    std.testing.refAllDecls(extend.tiled);
}
