const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const options = @import("options");

const platform = @import("internal/platform.zig");
const zhu = @import("zhu.zig");
const assets = @import("assets.zig");
const audio = @import("audio.zig");
const camera = @import("camera.zig");
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

pub const Option = struct {
    pack: ?assets.Pack = null,
    logicSize: ?zhu.Vector = null, // 默认游戏逻辑尺寸，省略时使用请求的窗口尺寸。
    scaleEnum: ScaleEnum = .stretch, // 缩放模式
    disableIME: bool = true, // 禁用输入法
    alignment: zhu.Vector = .center, // 对齐方式
    init: ?fn (std.mem.Allocator) void = null,
    event: fn (*const Event) void = handleEvent,
    frame: fn (f32) void,
    deinit: ?fn (std.mem.Allocator) void = null,
};

pub var size: zhu.Vector = .zero; // 实际窗口渲染像素尺寸，包含黑边，随窗口变化。
// 默认游戏画面在窗口中的像素区域，由缩放模式计算，不随绘制切换而改变。
pub var viewRect: zhu.Rect = undefined;
pub var scale: zhu.Vector = .one; // 默认游戏画面从逻辑坐标到窗口像素的比例。
var scaleEnum: ScaleEnum = undefined;
var alignment: zhu.Vector = undefined;

var allocator: std.mem.Allocator = undefined;

pub fn setup(gpa: std.mem.Allocator) void {
    allocator = gpa;
    key.mayNotHave = platform.mayNotHaveKeyboard();
}

// 请求的窗口尺寸在高 DPI 下不等于实际渲染像素。
pub fn run(title: [:0]const u8, size_: zhu.Vector, comptime option: Option) void {
    sk.time.setup();
    scaleEnum = option.scaleEnum;
    alignment = option.alignment;
    camera.init(option.logicSize orelse size_);
    viewRect = .init(.zero, camera.size);

    const cb = Handler(option);
    const desc: sk.app.Desc = .{
        .window_title = title,
        .width = @intFromFloat(size_.x),
        .height = @intFromFloat(size_.y),
        .depth_format = .NONE,
        .init_cb = cb.init,
        .event_cb = cb.event,
        .frame_cb = cb.frame,
        .cleanup_cb = cb.deinit,
        .allocator = assets.sokolAllocator(sk.app.Allocator),
        .high_dpi = true,
        .logger = .{ .func = sk.log.func },
    };
    platform.run(desc, option.disableIME);
}

fn Handler(comptime option: Option) type {
    return struct {
        fn init() callconv(.c) void {
            windowInit(option.pack);
            if (option.init) |func| func(allocator);
        }

        fn event(raw: ?*const Event) callconv(.c) void {
            if (raw) |ev| option.event(ev);
        }

        fn frame() callconv(.c) void {
            const start = sk.time.now();
            option.frame(beginFrame());
            endFrame(start);
        }

        fn deinit() callconv(.c) void {
            if (option.deinit) |func| func(allocator);
            windowDeinit();
        }
    };
}

fn windowInit(pack: ?assets.Pack) void {
    computeViewRect();
    sk.gfx.setup(.{
        .environment = sk.glue.environment(),
        .logger = .{ .func = sk.log.func },
        .allocator = assets.sokolAllocator(sk.gfx.Allocator),
    });
    assets.init(pack);
    zhu.random.init(sk.time.now());
}

fn beginFrame() f32 {
    assets.update();
    if (resized) computeViewRect();
    if (anyMoved()) {
        mouse.pos = mouse.raw.sub(viewRect.min).div(scale);
        for (&touch.points) |*slot| {
            if (slot.*) |*point| {
                point.pos = point.raw.sub(viewRect.min).div(scale);
            }
        }
    }
    const delta: f32 = @floatCast(sk.app.frameDuration());
    if (options.font == .system) text.system.update(delta);
    return delta;
}

fn endFrame(start: u64) void {
    endInput();
    resized = false;
    frameTicks = sk.time.since(start);
}

fn windowDeinit() void {
    audio.deinit();
    assets.deinit();
    sk.gfx.shutdown();
    if (builtin.abi.isAndroid()) platform.backend.threaded.deinit();
}

// 本帧窗口尺寸是否变化，供游戏读取，帧末清除。
pub var resized: bool = false;

// 默认窗口和输入处理；应用覆盖 event 后可按需转发。
pub fn handleEvent(ev: *const Event) void {
    switch (ev.type) {
        .RESIZED => {
            resized = true;
            mouse.moved, touch.moved = .{ true, true };
        },
        .KEY_DOWN, .KEY_UP => {
            // 键盘编号保持 Sokol 原值。
            const code: key.Code = @fromBackingInt(@backingInt(ev.key_code));
            key.set(code, ev.type == .KEY_DOWN);
        },
        .MOUSE_MOVE => {
            mouse.moved = true;
            mouse.raw = .xy(ev.mouse_x, ev.mouse_y);
            if (touch.points[touch.mouseIndex]) |*point| {
                if (point.state == .held) {
                    point.raw = mouse.raw;
                    touch.moved = true;
                }
            }
        },
        .MOUSE_DOWN, .MOUSE_UP => mouse_button: {
            // 鼠标编号加一，对应 MOUSE_LEFT、MOUSE_RIGHT、MOUSE_MIDDLE。
            const code = @backingInt(ev.mouse_button) + 1;
            key.set(@fromBackingInt(code), ev.type == .MOUSE_DOWN);
            mouse.raw = .xy(ev.mouse_x, ev.mouse_y);
            mouse.moved = true;
            if (ev.mouse_button != .LEFT) break :mouse_button;

            // 鼠标左键固定使用最后一个槽位，结束后同样保留到帧末。
            if (ev.type == .MOUSE_DOWN) {
                touch.points[touch.mouseIndex] = .{
                    .id = 0,
                    .start = mouse.raw,
                    .raw = mouse.raw,
                };
            } else if (touch.points[touch.mouseIndex]) |*point| {
                point.raw = mouse.raw;
                point.state = .ended;
            }
            touch.moved = true;
        },
        .MOUSE_SCROLL => mouse.scrollY += ev.scroll_y,
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            if (!touch.hasTouch) return;
            for (ev.touches[0..@intCast(ev.num_touches)]) |point| {
                if (!point.changed) continue;
                touch.moved = true;
                const raw: zhu.Vector = .xy(point.pos_x, point.pos_y);
                if (ev.type == .TOUCHES_BEGAN) {
                    press.pressed = true;
                    // 真实触点不使用鼠标槽位，ID 不作为数组索引。
                    const points = touch.points[0..touch.mouseIndex];
                    const index = for (points, 0..) |slot, i| {
                        if (slot == null) break i;
                    } else @panic("too many touch points");
                    touch.points[index] = .{
                        .id = point.identifier,
                        .start = raw,
                        .raw = raw,
                    };
                }

                // 所有触摸事件统一查找触点，并更新当前位置。
                const saved = touch.find(point.identifier).?;
                saved.raw = raw;
                switch (ev.type) {
                    .TOUCHES_BEGAN, .TOUCHES_MOVED => {},
                    .TOUCHES_ENDED => {
                        press.released = true;
                        saved.state = .ended;
                    },
                    .TOUCHES_CANCELLED => {
                        press.cancelled = true;
                        saved.state = .cancelled;
                    },
                    else => unreachable,
                }
            }
        },
        .ICONIFIED, .UNFOCUSED => resetInput(),
        else => {},
    }
}

// 按实际窗口像素和默认逻辑尺寸计算画面区域及输入、字体共用的缩放比例。
pub fn computeViewRect() void {
    size = .xy(sk.app.widthf(), sk.app.heightf());
    const logicSize = camera.size;
    const ratio = size.div(logicSize);
    viewRect = switch (scaleEnum) {
        .none => .init(size.sub(logicSize).mul(alignment), logicSize),
        .stretch => .init(.zero, size),
        .fit => blk: {
            const minSize = logicSize.scale(@min(ratio.x, ratio.y));
            const position = size.sub(minSize).mul(alignment);
            break :blk .init(position, minSize);
        },
        .fill => blk: {
            const maxSize = logicSize.scale(@max(ratio.x, ratio.y));
            const position = size.sub(maxSize).mul(alignment);
            break :blk .init(position, maxSize);
        },
        .integer => blk: {
            const min = @min(ratio.x, ratio.y);
            const usedScale = if (min < 1) min else @trunc(min);
            const intSize = logicSize.scale(usedScale);
            const position = size.sub(intSize).mul(alignment);
            break :blk .init(position, intSize);
        },
    };
    // 先对齐尺寸，再按最终尺寸计算整数像素位置。
    viewRect.size = viewRect.size.round().max(.one);
    viewRect.min = size.sub(viewRect.size).mul(alignment).round();
    scale = viewRect.size.div(logicSize);
}

pub var frameTicks: u64 = 0;

// 返回界面单位到渲染像素的倍率，安卓额外应用系统界面密度。
pub fn dpi() f32 {
    const bufferScale = sk.app.dpiScale();
    if (!builtin.abi.isAndroid()) return bufferScale;
    return bufferScale * platform.backend.density();
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
pub fn loadCursor(path: []const u8, desc: CursorDesc) void {
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

pub fn useCursor(path: []const u8, desc: CursorDesc) void {
    assets.loadIcon(path, @bitCast(desc), struct {
        fn callback(handle: u64, icon: assets.Icon) void {
            mouseCallback(handle, icon);
            const cursorDesc: CursorDesc = @bitCast(handle);
            setCursor(cursorDesc.cursor);
        }
    }.callback);
}

pub fn useWindowIcon(path: []const u8) void {
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

// 当前帧收到的按压变化。
pub const Press = struct {
    pressed: bool = false,
    released: bool = false,
    cancelled: bool = false, // 触摸被取消，单独记录，不作为正常释放。

    // 本帧是否收到按下、释放或取消。
    pub fn changed(self: Press) bool {
        return self.pressed or self.released or self.cancelled;
    }
};

// 当前帧收到的键盘、鼠标按钮和触屏按下、松开及触摸取消。
pub var press: Press = .{};

// 本帧是否有鼠标或触点移动。
pub fn anyMoved() bool {
    return mouse.moved or touch.moved;
}

// 本帧是否有按压变化、鼠标移动或触点移动。
pub fn inputChanged() bool {
    return press.changed() or anyMoved();
}

// 帧末清除本帧变化，并回放虚拟按键供下一帧读取。
pub fn endInput() void {
    key.pressedState = .empty;
    key.releasedState = .empty;
    mouse.scrollY = 0;
    press = .{};
    mouse.moved = false;
    touch.moved = false;

    // 帧末清理结束的触点，其余触点保留位置并清除本帧变化。
    for (&touch.points) |*slot| {
        if (slot.*) |*point| {
            point.began = false;
            if (point.state != .held) slot.* = null;
        }
    }

    // 清除本帧变化后，按顺序回放虚拟按键，供下一帧读取变化。
    for (key.events[0..key.eventCount]) |event| {
        key.set(event.code, event.down);
    }
    key.eventCount = 0;
}

pub fn resetInput() void {
    touch.points = @splat(null);
    touch.moved = false;
    key.state = .empty;
    key.pressedState = .empty;
    key.releasedState = .empty;
    key.eventCount = 0;
    mouse.scrollY = 0;
    press = .{};
    mouse.moved = false;
}

pub const key = struct {
    // 合并键盘和鼠标按钮，键盘保留原值，鼠标使用空闲编号 1、2、3。
    pub const Code = code: {
        const keys = std.enums.values(sk.app.Keycode);
        const buttons = std.enums.values(sk.app.Mousebutton);
        var names: [keys.len + buttons.len - 1][]const u8 = undefined;
        var values: [names.len]i32 = undefined;

        for (keys, 0..) |value, i| {
            names[i] = @tagName(value);
            values[i] = @backingInt(value);
        }

        // 鼠标项加前缀，跳过 INVALID，避免与键盘项重名。
        for (buttons, keys.len..) |value, index| {
            if (value == .INVALID) break;
            names[index] = "MOUSE_" ++ @tagName(value);
            values[index] = @backingInt(value) + 1;
        }

        break :code @Enum(i32, .exhaustive, &names, &values);
    };

    // setup 时根据平台和主要指针类型推测可能没有实体键盘。
    pub var mayNotHave: bool = false;

    // 键盘键和鼠标按钮共用按住状态，按下和释放分别保留到帧末。
    var state: std.StaticBitSet(512) = .empty;
    var pressedState: std.StaticBitSet(512) = .empty;
    var releasedState: std.StaticBitSet(512) = .empty;

    // 按产生顺序暂存虚拟按键，避免分开保存按下和释放导致顺序变化。
    const KeyEvent = struct { code: Code, down: bool };
    var events: [16]KeyEvent = undefined;
    var eventCount: u8 = 0;

    // 直接写入统一按键状态，并记录本帧输入变化。
    pub fn set(keyCode: Code, down: bool) void {
        const code: usize = @intCast(@backingInt(keyCode));
        // 忽略重复按下和没有对应按住状态的释放。
        if (state.isSet(code) == down) return;
        press.pressed = press.pressed or down;
        press.released = press.released or !down;
        state.setValue(code, down);
        if (down) pressedState.set(code) else releasedState.set(code);
    }

    // 暂存按键变化，帧末回放后在下一帧生效。
    // 每帧最多 16 个事件，超限由安全构建的数组边界检查报错。
    pub fn queue(keyCode: Code, down: bool) void {
        events[eventCount] = .{ .code = keyCode, .down = down };
        eventCount += 1;
    }

    pub fn held(keyCode: Code) bool {
        return state.isSet(@intCast(@backingInt(keyCode)));
    }

    pub fn pressed(keyCode: Code) bool {
        return pressedState.isSet(@intCast(@backingInt(keyCode)));
    }

    pub fn released(keyCode: Code) bool {
        return releasedState.isSet(@intCast(@backingInt(keyCode)));
    }

    pub fn anyHeld(keys: []const Code) bool {
        for (keys) |k| if (held(k)) return true;
        return false;
    }

    pub fn anyPressed(keys: []const Code) bool {
        for (keys) |k| if (pressed(k)) return true;
        return false;
    }

    pub fn anyReleased(keys: []const Code) bool {
        for (keys) |k| if (released(k)) return true;
        return false;
    }
};

pub const action = struct {
    pub const Action = std.meta.FieldEnum(@TypeOf(@import("action")));
    var bindings: std.EnumArray(Action, []const key.Code) = .init(@import("action"));

    pub fn get(id: Action) []const key.Code {
        return bindings.get(id);
    }

    /// 调用方负责保持切片有效，直到该绑定被替换。传空切片表示解绑。
    pub fn set(id: Action, keys: []const key.Code) void {
        bindings.set(id, keys);
    }

    pub fn held(id: Action) bool {
        return key.anyHeld(get(id));
    }

    pub fn pressed(id: Action) bool {
        return key.anyPressed(get(id));
    }

    pub fn released(id: Action) bool {
        return key.anyReleased(get(id));
    }
};

pub const mouse = struct {
    // 当前帧收到移动事件，或逻辑位置因视口变化而改变。
    pub var moved: bool = false;
    pub var raw: zhu.Vector = zhu.Vector.inf.neg(); // 原始像素坐标。
    // 帧开始时更新的游戏逻辑坐标；事件回调中仍为上一帧的值。
    pub var pos: zhu.Vector = zhu.Vector.inf.neg();
    pub var scrollY: f32 = 0;
    /// 鼠标捕获标记，由应用读写，引擎仅提供该字段。
    pub var captured: bool = false;

    // 判断鼠标逻辑坐标是否位于指定区域内。
    pub fn hover(area: anytype) bool {
        return area.contains(pos);
    }
};

pub const touch = struct {
    const hasTouch = builtin.abi.isAndroid() or
        builtin.os.tag == .ios or builtin.os.tag == .emscripten;
    // 桌面仅保留鼠标槽位，其他平台的鼠标槽位紧跟真实触点。
    const mouseIndex = if (hasTouch) (sk.app.Event{}).touches.len else 0;

    pub const Point = struct {
        id: usize, // 真实触点使用系统标识，鼠标固定为 0。
        start: zhu.Vector, // 按下时的原始像素坐标，后续保持不变。
        raw: zhu.Vector, // 原始像素坐标。
        // 帧开始时更新的游戏逻辑坐标，新触点在换算前不命中 UI。
        pos: zhu.Vector = zhu.Vector.inf.neg(),
        state: enum { held, ended, cancelled } = .held, // 当前触点状态。
        began: bool = true, // 本帧是否按下。
        /// 捕获保留到触点移除，避免松手那一帧被下层控件读到。
        captured: bool = false,

        // 同帧按下并松开仍可认领，取消的触点直接跳过。
        pub fn canCapture(self: Point) bool {
            return self.began and !self.captured and self.state != .cancelled;
        }
    };

    pub const Capture = struct {
        index: usize,
        frame: u64, // 上次认领或成功读取的帧。

        /// 每帧读取同一次按压，松开和取消的触点仍可读取到帧末。
        pub fn get(self: *Capture) ?*const Point {
            const frame = frameCount();
            const point = &(points[self.index] orelse return null);
            // 跳过更新可能漏掉新触点的 began，旧跟踪无法确认槽位归属。
            if (!point.captured or frame -% self.frame > 1) return null;
            if (point.began and frame != self.frame) return null;
            self.frame = frame;
            return point;
        }
    };

    // 区域内的触摸状态，包含鼠标左键。
    pub const State = struct {
        held: bool = false,
        pressed: bool = false,
        released: bool = false,
    };

    // 真实触点之后是鼠标左键，结束的触点保留到帧末。
    pub var points: [mouseIndex + 1]?Point = @splat(null);
    // 本帧有触点按下、移动，或逻辑位置因视口变化而改变。
    pub var moved: bool = false;

    /// 认领刚按下的触点，优先级由调用方的更新顺序决定。
    pub fn capture(index: usize) ?Capture {
        if (index >= points.len) return null;
        const point = &(points[index] orelse return null);
        if (!point.canCapture()) return null;

        point.captured = true;
        return .{ .index = index, .frame = frameCount() };
    }

    // 根据系统触点 ID 查找真实触点，不搜索鼠标槽位。
    fn find(id: usize) ?*Point {
        for (points[0..mouseIndex]) |*slot| {
            const point = &(slot.* orelse continue);
            if (point.id == id) return point;
        }
        return null;
    }

    // 查询任意触摸或鼠标左键是否释放，包含黑边。
    pub fn anyReleased() bool {
        for (points) |slot| {
            const point = slot orelse continue;
            if (point.state == .ended) return true;
        }
        return false;
    }

    // 按游戏逻辑坐标查询区域内未捕获的触摸和鼠标左键。
    pub fn query(area: anytype) State {
        var result: State = .{};
        for (points) |slot| {
            const point = slot orelse continue;
            if (point.captured or !area.contains(point.pos)) continue;
            result.held = result.held or point.state == .held;
            result.pressed = result.pressed or point.began;
            result.released = result.released or point.state == .ended;
        }
        return result;
    }
};
