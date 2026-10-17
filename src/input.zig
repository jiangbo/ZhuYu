const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const math = @import("math.zig");

// 当前帧收到的输入变化。
pub const Change = struct {
    pressed: bool = false,
    released: bool = false,

    pub fn any(self: Change) bool {
        return self.pressed or self.released;
    }
};

// 当前帧收到的键盘、鼠标按钮和触屏按下、松开变化。
pub var change: Change = .{};

// 本次事件使用的坐标转换参数，默认保持原始坐标。
pub const Option = struct {
    offset: math.Vector = .zero, // 视口起点，原始坐标减去此偏移。
    scale: math.Vector = .one, // 视口缩放比例。
};

// 键盘和鼠标按钮写入按键状态，触摸保存触点并记录按下、松开。
pub fn handle(ev: *const sk.app.Event, option: Option) void {
    switch (ev.type) {
        .KEY_DOWN, .KEY_UP => {
            // 键盘编号保持 Sokol 原值。
            const code: key.Code = @fromBackingInt(@backingInt(ev.key_code));
            key.set(code, ev.type == .KEY_DOWN);
        },
        .MOUSE_MOVE => {
            mouse.moved = true;
            mouse.raw = .xy(ev.mouse_x, ev.mouse_y);
            mouse.pos = mouse.raw.sub(option.offset).div(option.scale);
        },
        .MOUSE_DOWN, .MOUSE_UP => {
            // 鼠标编号加一，对应 MOUSE_LEFT、MOUSE_RIGHT、MOUSE_MIDDLE。
            const code = @backingInt(ev.mouse_button) + 1;
            key.set(@fromBackingInt(code), ev.type == .MOUSE_DOWN);
        },
        .MOUSE_SCROLL => mouse.scrollY += ev.scroll_y,
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            for (ev.touches[0..@intCast(ev.num_touches)]) |point| {
                if (!point.changed) continue;
                const raw: math.Vector = .xy(point.pos_x, point.pos_y);
                const pos = raw.sub(option.offset).div(option.scale);
                if (ev.type == .TOUCHES_BEGAN) {
                    change.pressed = true;
                    // 新触点占用第一个空槽位，ID 不直接作为数组索引。
                    const index = for (touch.points, 0..) |slot, i| {
                        if (slot == null) break i;
                    } else @panic("too many touch points");
                    touch.points[index] = std.mem.zeroInit(touch.Point, .{
                        .id = point.identifier,
                        .start = raw,
                    });
                }

                // 所有触摸事件统一查找触点，并更新当前位置。
                const saved = touch.find(point.identifier).?;
                saved.raw, saved.pos = .{ raw, pos };
                switch (ev.type) {
                    .TOUCHES_BEGAN, .TOUCHES_MOVED => touch.moved = true,
                    .TOUCHES_ENDED => {
                        change.released = true;
                        saved.state = .ended;
                    },
                    .TOUCHES_CANCELLED => saved.state = .cancelled,
                    else => unreachable,
                }
            }
        },
        .ICONIFIED, .UNFOCUSED => reset(),
        else => {},
    }
}

pub fn update() void {
    key.lastState = key.state;
    mouse.scrollY = 0;
    change = .{};
    mouse.moved = false;
    touch.moved = false;

    // 帧末清理结束的触点，其余触点保留位置并清除本帧变化。
    for (&touch.points) |*slot| {
        if (slot.*) |*point| {
            point.began = false;
            if (point.state != .held) slot.* = null;
        }
    }
}

pub fn reset() void {
    touch.points = @splat(null);
    touch.moved = false;
    key.state = .empty;
    key.lastState = .empty;
    mouse.scrollY = 0;
    change = .{};
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

    // 键盘键和鼠标按钮共用当前帧与上一帧的状态。
    var lastState: std.StaticBitSet(512) = .empty;
    var state: std.StaticBitSet(512) = .empty;

    // 直接写入统一按键状态，并记录本帧输入变化。
    pub fn set(keyCode: Code, down: bool) void {
        const code: usize = @intCast(@backingInt(keyCode));
        change.pressed = change.pressed or down;
        change.released = change.released or !down;
        state.setValue(code, down);
    }

    pub fn held(keyCode: Code) bool {
        return state.isSet(@intCast(@backingInt(keyCode)));
    }

    pub fn pressed(keyCode: Code) bool {
        const code: usize = @intCast(@backingInt(keyCode));
        return !lastState.isSet(code) and state.isSet(code);
    }

    pub fn released(keyCode: Code) bool {
        const code: usize = @intCast(@backingInt(keyCode));
        return lastState.isSet(code) and !state.isSet(code);
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
    // 当前帧鼠标位置是否变化。
    pub var moved: bool = false;
    pub var raw: math.Vector = math.Vector.inf.neg(); // 原始像素坐标。
    // 游戏逻辑坐标，收到鼠标位置事件前不命中 UI 矩形。
    pub var pos: math.Vector = math.Vector.inf.neg();
    pub var scrollY: f32 = 0;

    // 判断鼠标逻辑坐标是否位于矩形内。
    pub fn hover(rect: math.Rect) bool {
        return rect.contains(pos);
    }
};

pub const touch = struct {
    pub const Point = struct {
        id: usize, // 系统分配的触点标识。
        start: math.Vector, // 按下时的原始像素坐标，后续保持不变。
        raw: math.Vector, // 原始像素坐标。
        pos: math.Vector, // 游戏逻辑坐标。
        state: enum { held, ended, cancelled } = .held, // 当前触点状态。
        began: bool = true, // 本帧是否按下。
    };

    // 区域内的触摸状态，包含鼠标左键。
    pub const State = struct {
        held: bool = false,
        pressed: bool = false,
        released: bool = false,
    };

    // 结束的触点保留到帧末，游戏可以读取本帧发生的所有变化标记。
    pub var points: [8]?Point = @splat(null);
    // 本帧是否有触点按下或移动。
    pub var moved: bool = false;

    // 根据触点 ID 返回槽位中实际触点的指针。
    fn find(id: usize) ?*Point {
        for (&points) |*slot| {
            const point = &(slot.* orelse continue);
            if (point.id == id) return point;
        }
        return null;
    }

    // 按默认坐标查询区域内的触摸和鼠标左键。
    pub fn query(rect: math.Rect) State {
        return queryArea(rect, false);
    }

    // 按实际像素坐标查询区域内的触摸和鼠标左键，包含黑边。
    pub fn queryRaw(rect: math.Rect) State {
        return queryArea(rect, true);
    }

    // 复用区域查询，仅切换触点和鼠标使用的位置字段。
    fn queryArea(rect: math.Rect, comptime useRaw: bool) State {
        var result: State = .{};
        const mousePosition = if (useRaw) mouse.raw else mouse.pos;
        if (rect.contains(mousePosition)) {
            result.held = key.held(.MOUSE_LEFT);
            result.pressed = key.pressed(.MOUSE_LEFT);
            result.released = key.released(.MOUSE_LEFT);
        }

        for (points) |slot| {
            const point = slot orelse continue;
            const position = if (useRaw) point.raw else point.pos;
            if (!rect.contains(position)) continue;
            result.held = result.held or point.state == .held;
            result.pressed = result.pressed or point.began;
            result.released = result.released or point.state == .ended;
        }
        return result;
    }
};

pub const Bind = struct { action: []const u8, keys: []const key.Code };
pub fn bind(comptime binds: []const Bind) type {
    return struct {
        pub const Action = math.enums.fromField(binds, "action");

        pub fn held(action: Action) bool {
            return key.anyHeld(binds[@backingInt(action)].keys);
        }

        pub fn anyHeld(actions: []const Action) bool {
            for (actions) |action| if (held(action)) return true;
            return false;
        }

        pub fn pressed(action: Action) bool {
            return key.anyPressed(binds[@backingInt(action)].keys);
        }

        pub fn anyPressed(actions: []const Action) bool {
            for (actions) |action| if (pressed(action)) return true;
            return false;
        }

        pub fn released(action: Action) bool {
            return key.anyReleased(binds[@backingInt(action)].keys);
        }

        pub fn anyReleased(actions: []const Action) bool {
            for (actions) |action| if (released(action)) return true;
            return false;
        }
    };
}
