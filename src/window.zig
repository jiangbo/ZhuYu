const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const options = @import("options");
const root = @import("root");

const zhu = @import("zhu.zig");
const assets = @import("assets.zig");
const audio = @import("audio.zig");
const camera = @import("camera.zig");
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

pub const Option = struct {
    logicSize: ?zhu.Vector = null, // 默认游戏逻辑尺寸，省略时使用请求的窗口尺寸。
    scaleEnum: ScaleEnum = .stretch, // 缩放模式
    disableIME: bool = true, // 禁用输入法
    alignment: zhu.Vector = .center, // 对齐方式
};

pub var size: zhu.Vector = .zero; // 实际窗口渲染像素尺寸，包含黑边，随窗口变化。
// 默认游戏画面在窗口中的像素区域，由缩放模式计算，不随绘制切换而改变。
pub var viewRect: zhu.Rect = undefined;
pub var scale: zhu.Vector = .one; // 默认游戏画面从逻辑坐标到窗口像素的比例。
var info: Option = undefined; // 当前窗口配置，由 run 设置。
pub var io: std.Io = undefined; // 加载资源时使用的 IO

// 根据编译目标选择窗口及字体共用的平台实现。
pub const platform = switch (builtin.os.tag) {
    .windows => @import("internal/windows.zig"),
    .macos, .ios => @import("internal/apple.zig"),
    .linux => if (builtin.abi.isAndroid())
        @import("internal/android.zig")
    else
        @import("internal/linux.zig"),
    .emscripten => @import("internal/web.zig"),
    else => struct {},
};

pub fn call(object: anytype, comptime name: []const u8, args: anytype) void {
    if (@hasDecl(object, name)) @call(.auto, @field(object, name), args);
}

// 请求的窗口尺寸在高 DPI 下不等于实际渲染像素。
pub fn run(title: [:0]const u8, size_: zhu.Vector, option: Option) void {
    const desc = createDesc(title, size_, option);
    if (builtin.os.tag == .windows) {
        if (info.disableIME) _ = platform.ImmDisableIME(-1);
    }
    if (!builtin.abi.isAndroid()) return sk.app.run(desc);
    platform.desc = desc;
}

fn createDesc(title: [:0]const u8, s: zhu.Vector, o: Option) sk.app.Desc {
    sk.time.setup();
    info = o;
    camera.init(info.logicSize orelse s);
    viewRect = .init(.zero, camera.size);

    return .{
        .window_title = title,
        .width = @intFromFloat(s.x),
        .height = @intFromFloat(s.y),
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
    assets.init(io);
    zhu.random.init(sk.time.now());
    call(root, "init", .{memory.allocator});
}

// 本帧窗口尺寸是否变化，供游戏读取，帧末清除。
pub var resized: bool = false;

export fn windowEvent(raw: ?*const Event) void {
    const ev = raw orelse return;
    if (@hasDecl(root, "event")) return root.event(ev);
    handleEvent(ev);
}

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
    // 先对齐尺寸，再按最终尺寸计算整数像素位置。
    viewRect.size = viewRect.size.round();
    viewRect.min = size.sub(viewRect.size).mul(info.alignment).round();
    scale = viewRect.size.div(logicSize);
}

pub var frameTicks: u64 = 0;
export fn windowFrame() void {
    const frameStart = sk.time.now();
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
    if (options.font == .system) text.dynamic.update(delta);
    call(root, "frame", .{delta});
    endInput();
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

    // 根据平台推测可能没有实体键盘，浏览器初始化时查询主要指针类型。
    pub var mayNotHave: bool = builtin.target.abi.isAndroid() or
        builtin.os.tag == .ios;

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
        press.pressed = press.pressed or down;
        press.released = press.released or !down;
        // 系统重复发送按下事件时，不产生新的按下边沿。
        if (state.isSet(code) == down) return;
        state.setValue(code, down);
        if (down) pressedState.set(code) else releasedState.set(code);
    }

    // 暂存按键变化，帧末回放后在下一帧生效。
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

pub const mouse = struct {
    // 当前帧收到移动事件，或逻辑位置因视口变化而改变。
    pub var moved: bool = false;
    pub var raw: zhu.Vector = zhu.Vector.inf.neg(); // 原始像素坐标。
    // 帧开始时更新的游戏逻辑坐标；事件回调中仍为上一帧的值。
    pub var pos: zhu.Vector = zhu.Vector.inf.neg();
    pub var scrollY: f32 = 0;

    // 判断鼠标逻辑坐标是否位于指定区域内。
    pub fn hover(area: anytype) bool {
        return area.contains(pos);
    }
};

pub const touch = struct {
    // 鼠标槽位紧跟 Sokol 提供的真实触点槽位。
    const mouseIndex = (sk.app.Event{}).touches.len;

    pub const Point = struct {
        id: usize, // 真实触点使用系统标识，鼠标固定为 0。
        start: zhu.Vector, // 按下时的原始像素坐标，后续保持不变。
        raw: zhu.Vector, // 原始像素坐标。
        // 帧开始时更新的游戏逻辑坐标，新触点在换算前不命中 UI。
        pos: zhu.Vector = zhu.Vector.inf.neg(),
        state: enum { held, ended, cancelled } = .held, // 当前触点状态。
        began: bool = true, // 本帧是否按下。
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

    // 按游戏逻辑坐标查询矩形、圆形等区域内的触摸和鼠标左键。
    pub fn query(area: anytype) State {
        var result: State = .{};
        for (points) |slot| {
            const point = slot orelse continue;
            if (!area.contains(point.pos)) continue;
            result.held = result.held or point.state == .held;
            result.pressed = result.pressed or point.began;
            result.released = result.released or point.state == .ended;
        }
        return result;
    }
};

pub const Bind = struct { action: []const u8, keys: []const key.Code };
/// 接受动作枚举或默认配置列表；枚举方式初始不绑定任何按键。
pub fn bind(comptime binds: anytype) type {
    const isEnum = @TypeOf(binds) == type;
    const defaults = if (isEnum) &.{} else binds;
    const E = if (isEnum) binds else zhu.enums.fromField(defaults, "action");

    return struct {
        pub const Action = E;

        const Entry = struct {
            keys: [4]key.Code = @splat(.INVALID),
            len: u8 = 0,
        };

        var entries: std.EnumArray(Action, Entry) = init: {
            var result: std.EnumArray(Action, Entry) = .initFill(.{});
            for (defaults, 0..) |binding, index| {
                const action: Action = @fromBackingInt(index);
                const entry = result.getPtr(action);
                if (binding.keys.len > entry.keys.len)
                    @compileError("each action supports at most 4 keys");
                for (binding.keys, 0..) |code, i| entry.keys[i] = code;
                entry.len = @intCast(binding.keys.len);
            }
            break :init result;
        };

        /// 复制按键配置；空切片表示解绑，最多传入 4 个键。
        pub fn set(action: Action, keys: []const key.Code) void {
            const entry = entries.getPtr(action);
            std.debug.assert(keys.len <= entry.keys.len);
            std.mem.copyForwards(key.Code, entry.keys[0..keys.len], keys);
            @memset(entry.keys[keys.len..], .INVALID);
            entry.len = @intCast(keys.len);
        }

        /// 返回内部按键切片，内容会随 set 改变。
        pub fn get(action: Action) []const key.Code {
            const entry = entries.getPtrConst(action);
            return entry.keys[0..entry.len];
        }

        pub fn held(action: Action) bool {
            return key.anyHeld(get(action));
        }

        pub fn anyHeld(actions: []const Action) bool {
            for (actions) |action| if (held(action)) return true;
            return false;
        }

        pub fn pressed(action: Action) bool {
            return key.anyPressed(get(action));
        }

        pub fn anyPressed(actions: []const Action) bool {
            for (actions) |action| if (pressed(action)) return true;
            return false;
        }

        pub fn released(action: Action) bool {
            return key.anyReleased(get(action));
        }

        pub fn anyReleased(actions: []const Action) bool {
            for (actions) |action| if (released(action)) return true;
            return false;
        }
    };
}
