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

// 当前帧收到的所有键盘和鼠标按钮变化。
pub var change: Change = .{};

// 本次事件使用的坐标转换参数，默认保持原始坐标。
pub const Option = struct {
    offset: math.Vector = .zero, // 视口起点，原始坐标减去此偏移。
    scale: math.Vector = .one, // 视口缩放比例。
};

// 将键盘、鼠标和触摸事件写入各自的输入状态。
pub fn handle(ev: *const sk.app.Event, option: Option) void {
    const keyCode: usize = @intCast(@backingInt(ev.key_code));
    const buttonCode: usize = @intCast(@backingInt(ev.mouse_button));

    switch (ev.type) {
        .KEY_DOWN => {
            change.pressed = true;
            key.change.pressed = true;
            key.state.set(keyCode);
        },
        .KEY_UP => {
            change.released = true;
            key.change.released = true;
            key.state.unset(keyCode);
        },
        .MOUSE_MOVE => {
            mouse.moved = true;
            mouse.raw = .xy(ev.mouse_x, ev.mouse_y);
            mouse.pos = mouse.raw.sub(option.offset).div(option.scale);
        },
        .MOUSE_DOWN => {
            change.pressed = true;
            mouse.change.pressed = true;
            mouse.state.set(buttonCode);
        },
        .MOUSE_UP => {
            change.released = true;
            mouse.change.released = true;
            mouse.state.unset(buttonCode);
        },
        .MOUSE_SCROLL => mouse.scrollY += ev.scroll_y,
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            for (ev.touches[0..@intCast(ev.num_touches)]) |point| {
                if (!point.changed) continue;
                const raw: math.Vector = .xy(point.pos_x, point.pos_y);
                const pos = raw.sub(option.offset).div(option.scale);
                if (ev.type == .TOUCHES_BEGAN) {
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
                    .TOUCHES_ENDED => saved.state = .ended,
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
    mouse.lastState = mouse.state;
    mouse.scrollY = 0;
    change = .{};
    key.change = .{};
    mouse.change = .{};
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
    mouse.state = .empty;
    mouse.lastState = .empty;
    mouse.scrollY = 0;
    change = .{};
    key.change = .{};
    mouse.change = .{};
    mouse.moved = false;
}

pub const key = struct {
    pub const Code = sk.app.Keycode;

    // 根据平台推测是否有键盘，浏览器在引擎初始化时查询主要指针类型。
    pub var mayHave: bool = !builtin.target.abi.isAndroid() and
        builtin.os.tag != .ios;

    pub var change: Change = .{};
    var lastState: std.StaticBitSet(512) = .empty;
    var state: std.StaticBitSet(512) = .empty;

    pub fn set(keyCode: Code, down: bool) void {
        handle(&sk.app.Event{
            .type = if (down) .KEY_DOWN else .KEY_UP,
            .key_code = keyCode,
        }, .{});
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
    pub const Button = sk.app.Mousebutton;

    pub var change: Change = .{};
    // 当前帧鼠标位置是否变化。
    pub var moved: bool = false;
    pub var raw: math.Vector = math.Vector.inf.neg(); // 原始像素坐标。
    // 游戏逻辑坐标，收到鼠标位置事件前不命中 UI 矩形。
    pub var pos: math.Vector = math.Vector.inf.neg();
    pub var scrollY: f32 = 0;
    var lastState: std.StaticBitSet(3) = .empty;
    var state: std.StaticBitSet(3) = .empty;

    pub fn set(button: Button, down: bool) void {
        handle(&sk.app.Event{
            .type = if (down) .MOUSE_DOWN else .MOUSE_UP,
            .mouse_button = button,
        }, .{});
    }

    // 判断鼠标逻辑坐标是否位于矩形内。
    pub fn hover(rect: math.Rect) bool {
        return rect.contains(pos);
    }

    pub fn held(button: Button) bool {
        return state.isSet(@intCast(@backingInt(button)));
    }

    pub fn pressed(button: Button) bool {
        const code: usize = @intCast(@backingInt(button));
        return !lastState.isSet(code) and state.isSet(code);
    }

    pub fn released(button: Button) bool {
        const code: usize = @intCast(@backingInt(button));
        return lastState.isSet(code) and !state.isSet(code);
    }

    pub fn anyReleased(buttons: []const Button) bool {
        for (buttons) |button| if (released(button)) return true;
        return false;
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

    // 统一查询触摸和鼠标左键，每个位置只判断一次。
    pub fn query(rect: math.Rect) State {
        var result: State = .{};
        if (mouse.hover(rect)) {
            result.held = mouse.held(.LEFT);
            result.pressed = mouse.pressed(.LEFT);
            result.released = mouse.released(.LEFT);
        }

        for (points) |slot| {
            const point = slot orelse continue;
            if (!rect.contains(point.pos)) continue;
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
