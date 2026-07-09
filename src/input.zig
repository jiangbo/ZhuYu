const std = @import("std");
const sk = @import("sokol");
const math = @import("math.zig");

pub fn handle(ev: *const sk.app.Event) void {
    const keyCode: u16 = @intCast(@intFromEnum(ev.key_code));
    const buttonCode: u16 = @intCast(@intFromEnum(ev.mouse_button));

    if (ev.type == .KEY_DOWN or ev.type == .KEY_UP) key.changed = true;
    if (math.enums.inRange(ev.type, .MOUSE_DOWN, .MOUSE_LEAVE)) {
        mouse.changed = true;
    }

    switch (ev.type) {
        .KEY_DOWN => key.state.set(keyCode),
        .KEY_UP => key.state.unset(keyCode),
        .MOUSE_MOVE => mouse.raw = .xy(ev.mouse_x, ev.mouse_y),
        .MOUSE_DOWN => mouse.state.set(buttonCode),
        .MOUSE_UP => mouse.state.unset(buttonCode),
        .MOUSE_SCROLL => mouse.scrollY += ev.scroll_y,
        .ICONIFIED, .UNFOCUSED => reset(),
        else => {},
    }
}

pub fn update() void {
    key.lastState = key.state;
    mouse.lastState = mouse.state;
    mouse.scrollY = 0;
    key.changed = false;
    mouse.changed = false;
}

pub fn reset() void {
    key.state = .initEmpty();
    key.lastState = .initEmpty();
    mouse.state = .initEmpty();
    mouse.lastState = .initEmpty();
    mouse.scrollY = 0;
    key.changed = false;
    mouse.changed = false;
}

pub const key = struct {
    pub const Code = sk.app.Keycode;

    pub var changed: bool = false;
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
    pub var changed: bool = false;
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
