const std = @import("std");
const builtin = @import("builtin");

const sk = @import("sokol");
const math = @import("math.zig");
const assets = @import("assets.zig");
const audio = @import("audio.zig");
const camera = @import("camera.zig");
const input = @import("input.zig");
const memory = @import("internal/memory.zig");
const text = @import("text.zig");

pub const Event = sk.app.Event;

/// 缩放模式枚举
pub const ScaleEnum = enum {
    none, // 无缩放，使用原始尺寸
    stretch, // 拉伸缩放，忽略宽高比填满屏幕
    fit, // 适配缩放，保持宽高比可能有黑边
    fill, // 填充缩放，保持宽高比可能超出屏幕
    integer, // 整数缩放，整数倍数（无滤镜失真）
};

pub const Info = struct {
    title: [:0]const u8, // 窗口标题
    size: math.Vector, // 请求的窗口尺寸，高 DPI 下不等于实际渲染像素。
    logicSize: ?math.Vector = null, // 默认游戏逻辑尺寸，省略时使用请求的窗口尺寸。
    scaleEnum: ScaleEnum = .stretch, // 缩放模式
    disableIME: bool = true, // 禁用输入法
    alignment: math.Vector = .center, // 对齐方式
    maxFileSize: usize = 1 * 1024 * 1024, // 最大加载文件大小
};

pub var size: math.Vector = .zero; // 实际窗口渲染像素尺寸，包含黑边，随窗口变化。
// 默认游戏画面在窗口中的像素区域，由缩放模式计算，不随绘制切换而改变。
pub var viewRect: math.Rect = undefined;
pub var scale: math.Vector = .one; // 默认游戏画面从逻辑坐标到窗口像素的比例。
var info: Info = undefined; // 当前窗口配置，由 run 设置。
pub var io: std.Io = undefined; // 加载资源时使用的 IO

// 平台实现统一在这里选择，供入口、窗口和资源加载共用。
pub const platform = if (builtin.os.tag == .windows) struct {
    // 使用 Zig 自带的导入库名称，Linux 交叉编译时也能找到。
    pub extern "imm32" fn ImmDisableIME(i32) std.os.windows.BOOL;
} else if (builtin.abi.isAndroid())
    @import("internal/android.zig")
else
    struct {};

pub fn call(object: anytype, comptime name: []const u8, args: anytype) void {
    if (@hasDecl(object, name)) @call(.auto, @field(object, name), args);
}

const root = @import("root");

pub fn run(info_: Info) void {
    const desc = createDesc(info_);
    if (!builtin.abi.isAndroid()) return sk.app.run(desc);
    platform.desc = desc;
}

fn createDesc(info_: Info) sk.app.Desc {
    sk.time.setup();
    info = info_;
    camera.init(info.logicSize orelse info.size);
    viewRect = .init(.zero, camera.size);

    if (builtin.os.tag == .windows) {
        if (info.disableIME) _ = platform.ImmDisableIME(-1);
    }

    return .{
        .window_title = info.title,
        .width = @intFromFloat(info.size.x),
        .height = @intFromFloat(info.size.y),
        .depth_format = .NONE,
        .init_cb = windowInit,
        .event_cb = windowEvent,
        .frame_cb = windowFrame,
        .cleanup_cb = windowDeinit,
        .allocator = memory.sokolAllocator(sk.app.Allocator),
        .high_dpi = true,
        .logger = .{ .func = sk.log.func },
    };
}

export fn windowInit() void {
    computeViewRect();
    sk.gfx.setup(.{
        .environment = sk.glue.environment(),
        .logger = .{ .func = sk.log.func },
        .allocator = memory.sokolAllocator(sk.gfx.Allocator),
    });
    assets.init(io, info.maxFileSize);
    math.random.init(sk.time.now());
    call(root, "init", .{memory.allocator});
}

// 本帧窗口尺寸是否变化，供游戏读取，帧末清除。
pub var resized: bool = false;

export fn windowEvent(event: ?*const Event) void {
    if (event) |ev| {
        input.handle(ev, .{ .offset = viewRect.min, .scale = scale });
        if (ev.type == .RESIZED) resized = true;

        call(root, "event", .{ev});
    }
}

// 按实际窗口像素和默认逻辑尺寸计算画面区域及输入、字体共用的缩放比例。
pub fn computeViewRect() void {
    size = .xy(sk.app.widthf(), sk.app.heightf());
    const logicSize = camera.size;
    const ratio = size.div(logicSize);
    viewRect = switch (info.scaleEnum) {
        .none => .init(size.sub(logicSize).mul(info.alignment), logicSize),
        .stretch => .init(.zero, size),
        .fit => blk: {
            const minSize = logicSize.scale(@min(ratio.x, ratio.y));
            const position = size.sub(minSize).mul(info.alignment);
            break :blk .init(position, minSize);
        },
        .fill => blk: {
            const maxSize = logicSize.scale(@max(ratio.x, ratio.y));
            const position = size.sub(maxSize).mul(info.alignment);
            break :blk .init(position, maxSize);
        },
        .integer => blk: {
            const min = @min(ratio.x, ratio.y);
            const usedScale = if (min < 1) min else @trunc(min);
            const intSize = logicSize.scale(usedScale);
            const position = size.sub(intSize).mul(info.alignment);
            break :blk .init(position, intSize);
        },
    };
    scale = viewRect.size.div(logicSize);
}

pub var frameTicks: u64 = 0;
export fn windowFrame() void {
    const frameStart = sk.time.now();
    assets.update();
    if (resized) computeViewRect();
    const delta: f32 = @floatCast(sk.app.frameDuration());
    call(root, "frame", .{delta});
    input.update();
    resized = false;
    frameTicks = sk.time.since(frameStart);
}

export fn windowDeinit() void {
    call(root, "deinit", .{memory.allocator});
    audio.deinit();
    assets.deinit();
    sk.gfx.shutdown();
    if (builtin.abi.isAndroid()) platform.threaded.deinit();
}

// 返回界面单位到渲染像素的倍率，安卓额外应用系统界面密度。
pub fn dpi() f32 {
    const bufferScale = sk.app.dpiScale();
    if (!builtin.abi.isAndroid()) return bufferScale;
    return bufferScale * platform.density();
}

pub fn timestamp() std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .real);
}

pub const showCursor = sk.app.showMouse;
pub const toggleFullScreen = sk.app.toggleFullscreen;
pub const frameCount = sk.app.frameCount;

pub fn exit() void {
    sk.app.requestQuit();
}

pub const Cursor = sk.app.MouseCursor;
pub const setCursor = sk.app.setMouseCursor;
// 打包为图片加载回调的 64 位标识。
pub const CursorDesc = packed struct(u64) {
    cursor: Cursor = .CUSTOM_1,
    offset: packed struct { x: i16 = 0, y: i16 = 0 } = .{},
    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
    }
};
pub fn loadCursor(path: [:0]const u8, desc: CursorDesc) void {
    assets.loadIcon(path, @bitCast(desc), mouseCallback);
}

fn mouseCallback(handle: u64, icon: assets.Icon) void {
    const cursorDesc: CursorDesc = @bitCast(handle);
    _ = sk.app.bindMouseCursorImage(cursorDesc.cursor, .{
        .pixels = .{ .ptr = icon.data.ptr, .size = icon.data.len },
        .width = icon.width,
        .height = icon.height,
        .cursor_hotspot_x = cursorDesc.offset.x,
        .cursor_hotspot_y = cursorDesc.offset.y,
    });
}

pub fn useCursor(path: [:0]const u8, desc: CursorDesc) void {
    assets.loadIcon(path, @bitCast(desc), struct {
        fn callback(handle: u64, icon: assets.Icon) void {
            mouseCallback(handle, icon);
            const cursorDesc: CursorDesc = @bitCast(handle);
            setCursor(cursorDesc.cursor);
        }
    }.callback);
}

pub fn useWindowIcon(path: [:0]const u8) void {
    assets.loadIcon(path, 0, struct {
        fn callback(_: u64, icon: assets.Icon) void {
            var desc: sk.app.IconDesc = .{};
            desc.images[0] = .{
                .pixels = .{ .ptr = icon.data.ptr, .size = icon.data.len },
                .width = icon.width,
                .height = icon.height,
            };
            sk.app.setIcon(desc);
        }
    }.callback);
}

pub fn drawCenter(str: text.String, y: f32, option: text.Option) void {
    const textSize = text.measure(str, option);
    const pos = camera.size.mul(.xy(0.5, y)).sub(.xy(textSize.x / 2, 0));
    text.draw(str, pos, option);
}
