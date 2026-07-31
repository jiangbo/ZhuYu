const std = @import("std");
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

pub fn handle(ev: *const sk.app.Event) void {
    const keyCode: u16 = @intCast(@intFromEnum(ev.key_code));
    const buttonCode: u16 = @intCast(@intFromEnum(ev.mouse_button));

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
}

pub fn reset() void {
    key.state = .initEmpty();
    key.lastState = .initEmpty();
    mouse.state = .initEmpty();
    mouse.lastState = .initEmpty();
    mouse.scrollY = 0;
    change = .{};
    key.change = .{};
    mouse.change = .{};
    mouse.moved = false;
}

pub const key = struct {
    pub const Code = sk.app.Keycode;

    pub var change: Change = .{};
    var lastState: std.StaticBitSet(512) = .initEmpty();
    var state: std.StaticBitSet(512) = .initEmpty();

    pub fn set(keyCode: Code, down: bool) void {
        handle(&sk.app.Event{
            .type = if (down) .KEY_DOWN else .KEY_UP,
            .key_code = keyCode,
        });
    }

    pub fn held(keyCode: Code) bool {
        return state.isSet(@intCast(@intFromEnum(keyCode)));
    }

    pub fn pressed(keyCode: Code) bool {
        const code: usize = @intCast(@intFromEnum(keyCode));
        return !lastState.isSet(code) and state.isSet(code);
    }

    pub fn released(keyCode: Code) bool {
        const code: usize = @intCast(@intFromEnum(keyCode));
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
    pub var raw: math.Vector = .zero;
    pub var scrollY: f32 = 0;
    var lastState: std.StaticBitSet(3) = .initEmpty();
    var state: std.StaticBitSet(3) = .initEmpty();

    pub fn set(button: Button, down: bool) void {
        handle(&sk.app.Event{
            .type = if (down) .MOUSE_DOWN else .MOUSE_UP,
            .mouse_button = button,
        });
    }

    pub fn held(button: Button) bool {
        return state.isSet(@intCast(@intFromEnum(button)));
    }

    pub fn pressed(button: Button) bool {
        const code: usize = @intCast(@intFromEnum(button));
        return !lastState.isSet(code) and state.isSet(code);
    }

    pub fn released(button: Button) bool {
        const code: usize = @intCast(@intFromEnum(button));
        return lastState.isSet(code) and !state.isSet(code);
    }

    pub fn anyReleased(buttons: []const Button) bool {
        for (buttons) |button| if (released(button)) return true;
        return false;
    }
};

pub const Bind = struct { action: []const u8, keys: []const key.Code };
pub fn bind(comptime binds: []const Bind) type {
    return struct {
        pub const Action = math.enums.fromField(binds, "action");

        pub fn held(action: Action) bool {
            return key.anyHeld(binds[@intFromEnum(action)].keys);
        }

        pub fn anyHeld(actions: []const Action) bool {
            for (actions) |action| if (held(action)) return true;
            return false;
        }

        pub fn pressed(action: Action) bool {
            return key.anyPressed(binds[@intFromEnum(action)].keys);
        }

        pub fn anyPressed(actions: []const Action) bool {
            for (actions) |action| if (pressed(action)) return true;
            return false;
        }

        pub fn released(action: Action) bool {
            return key.anyReleased(binds[@intFromEnum(action)].keys);
        }

        pub fn anyReleased(actions: []const Action) bool {
            for (actions) |action| if (released(action)) return true;
            return false;
        }
    };
}
