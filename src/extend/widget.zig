const std = @import("std");

const zhu = @import("../zhu.zig");
const window = @import("../window.zig");
const camera = @import("../camera.zig");
const batch = @import("../batch.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const audio = @import("../audio.zig");
const assets = @import("../assets.zig");

const Vector2 = zhu.Vector2;

/// 管理画面淡出和淡入；遮罩绘制使用调用方的相机和渲染目标。
pub const Fade = struct {
    pub const Event = enum { covered, clear };
    const State = enum { clear, out, covered, in };

    timer: zhu.Timer,
    state: State = .clear,

    pub fn init(duration: f32) Fade {
        std.debug.assert(duration > 0);
        return .{ .timer = .init(duration) };
    }

    /// 从透明开始，完成后保持完全遮挡。
    pub fn fadeOut(self: *Fade) void {
        self.state = .out;
        self.timer.restart();
    }

    /// 从完全遮挡开始，完成后保持透明。
    pub fn fadeIn(self: *Fade) void {
        self.state = .in;
        self.timer.restart();
    }

    /// 每次完成只返回一次事件，不自动进入下一阶段。
    pub fn update(self: *Fade, delta: f32) ?Event {
        switch (self.state) {
            .clear, .covered => return null,
            .out, .in => {},
        }
        if (self.timer.updateRunning(delta)) return null;
        const event: Event = if (self.state == .out) .covered else .clear;
        self.state = if (event == .covered) .covered else .clear;
        return event;
    }

    /// 完全透明时为 false，淡出、完全遮挡和淡入期间均为 true。
    pub fn active(self: Fade) bool {
        return self.state != .clear;
    }

    /// 返回遮罩不透明度，可用于绘制遮罩或计算图片的可见程度。
    pub fn alpha(self: Fade) f32 {
        return switch (self.state) {
            .clear => 0,
            .out => self.timer.progress(),
            .covered => 1,
            .in => 1 - self.timer.progress(),
        };
    }

    pub fn draw(self: Fade, rect: zhu.Rect, color: graphics.Color) void {
        const opacity = self.alpha();
        if (opacity == 0) return;
        batch.drawRect(rect, .{ .color = color.scaleAlpha(opacity) });
    }
};

// 按钮配置与绘制，事件以 u16 编号。
pub const Button = struct {
    pub const State = enum { normal, hover, pressed, disabled };
    pub const Style = struct {
        color: ?graphics.Color = null,
        image: ?graphics.ImageId = null,
        source: ?zhu.Rect = null,
        text: text.Option = .{},
    };

    shape: zhu.Shape, // 命中和绘制共用的矩形或圆形区域。
    event: u16,
    label: []const u8 = "",
    patch: ?graphics.NineImage.Patch = null,
    normal: Style = .{},
    hover: Style = .{},
    pressed: Style = .{},
    disabled: Style = .{},

    // 根据状态返回对应样式。
    pub fn style(self: Button, state: State) Style {
        return switch (state) {
            .normal => self.normal,
            .hover => self.hover,
            .pressed => self.pressed,
            .disabled => self.disabled,
        };
    }

    // 根据形状绘制背景，并在区域内绘制图片。
    pub fn drawImage(self: Button, state: State, offset: Vector2) void {
        const visual = self.style(state);
        const shape = self.shape.move(offset);
        const rect = shape.toRect();
        if (visual.color) |color| switch (shape) {
            .rect => batch.drawRect(rect, .{ .color = color }),
            .circle => |circle| batch.drawCircle(circle.center, .{
                .size = rect.size,
                .anchor = .center,
                .color = color,
            }),
        };

        var image = assets.getImage(visual.image orelse return).?;
        if (visual.source) |source| image = image.sub(source);
        if (self.patch) |patch| {
            return batch.drawNine(.init(image, patch), rect);
        }
        batch.drawImage(image, rect.min, .{ .size = rect.size });
    }

    // 在区域中心绘制按钮文字，不切换文字流水线。
    pub fn drawText(self: Button, state: State, offset: Vector2) void {
        if (self.label.len == 0) return;
        var option = self.style(state).text;
        const position = self.shape.center().add(offset);
        if (option.anchor == null) option.anchor = .center;
        text.draw(self.label, position, option);
    }
};

// 用按下时的位置命中，避免从区域外滑进来的触点触发按钮。
fn capturePress(area: anytype) ?window.touch.Capture {
    for (window.touch.points, 0..) |slot, index| {
        const point = slot orelse continue;
        if (!point.canCapture()) continue;
        const start = point.start.sub(window.viewRect.min).div(window.scale);
        if (area.contains(start)) return window.touch.capture(index);
    }
    return null;
}

const PressState = enum { held, released };

fn pressState(press: *window.touch.Capture, area: anytype) ?PressState {
    const point = press.get() orelse return null;
    // 滑出就取消点击，触点仍保持捕获直到松手。
    if (!area.contains(point.pos)) return null;
    return switch (point.state) {
        .held => .held,
        .ended => .released,
        .cancelled => null,
    };
}

// 单个区域的点击状态，供游戏中的独立按钮使用。
pub const Click = struct {
    pressed: bool = false, // 是否已在区域内按下，且尚未取消或释放。
    touchPress: ?window.touch.Capture = null,

    // 每帧调用一次，区域内按下并释放才算点击。
    // 移出或取消即失效，再移回也不恢复。
    pub fn update(self: *Click, rect: zhu.Rect) bool {
        var state = if (self.touchPress) |*press| pressState(press, rect) else null;
        if (state == null) {
            self.touchPress = capturePress(rect);
            if (self.touchPress) |*press| state = pressState(press, rect);
        }

        self.pressed = state == .held;
        if (!self.pressed) self.touchPress = null;
        return state == .released;
    }
};

// 根据调用方提供的命中项跟踪鼠标点击。
pub fn ClickT(comptime T: type) type {
    return struct {
        hover: ?T = null,
        pressed: ?T = null,
        captured: bool = false,
        frame: u64 = 0,

        pub const empty: @This() = .{};

        pub fn update(self: *@This(), hover: ?T) ?T {
            const frame = window.frameCount();
            if (self.frame + 1 < frame) self.* = .empty;
            self.frame = frame;
            self.hover = hover;
            self.captured = hover != null or self.pressed != null;

            if (hover) |value| {
                if (window.key.pressed(.MOUSE_LEFT)) self.pressed = value;
            }
            if (!window.key.released(.MOUSE_LEFT)) return null;
            defer self.pressed = null;
            if (!std.meta.eql(self.pressed, hover)) return null;
            return hover;
        }
    };
}

pub const Popup = struct {
    anchor: Vector2,
    size: Vector2, // 实际尺寸：贴边定位 + clamp
    maxSize: ?Vector2 = null, // 翻转判断用的最大预期尺寸，缺省用 size
    offset: Vector2 = .zero,
    bounds: ?Vector2 = null,
};

pub fn popupPosition(popup: Popup) Vector2 {
    const bounds = popup.bounds orelse camera.size;
    const max = popup.maxSize orelse popup.size;
    var pos = popup.anchor.add(popup.offset);

    // 方向判断用 max（缺省为 size），贴边位置用 size（实际）
    if (pos.x + max.x > bounds.x) {
        pos.x = popup.anchor.x - popup.offset.x - popup.size.x;
    }
    if (pos.y + max.y > bounds.y) {
        pos.y = popup.anchor.y - popup.offset.y - popup.size.y;
    }

    return pos.clamp(.zero, bounds.sub(popup.size).max(.zero));
}

// 选中项和导航使用按钮下标，菜单返回配置的事件编号。
pub const Menu = struct {
    pub const Trigger = enum { press, release };

    pub const Nav = struct {
        pub const none: Nav = .{};

        up: bool = false,
        down: bool = false,
        confirm: bool = false,
        cancel: bool = false,
    };

    pub const NavKeys = struct {
        up: []const window.key.Code = &.{ .UP, .W },
        down: []const window.key.Code = &.{ .DOWN, .S },
        confirm: []const window.key.Code = &.{ .ENTER, .SPACE, .F },
        cancel: []const window.key.Code = &.{.ESCAPE},
    };

    pub const Option = struct {
        nav: ?Nav = null,
        wrap: bool = true,
    };

    position: zhu.Vector2 = .zero,
    overlay: ?graphics.Color = null,
    panel: struct {
        size: zhu.Vector2 = .zero,
        color: ?graphics.Color = null,
        image: ?graphics.ImageId = null,
        source: ?zhu.Rect = null,
    } = .{},
    title: struct {
        text: []const u8 = "",
        position: zhu.Vector2 = .zero,
        option: text.Option = .{ .anchor = .center },
    } = .{},
    buttons: []const Button = &.{},
    // 键盘导航、鼠标和触摸点击共用的触发时机。
    trigger: Trigger = .release,
    navKeys: NavKeys = .{},
    cancelEvent: ?u16 = null,
    hoverSound: ?[]const u8 = null,
    clickSound: ?[]const u8 = null,
    disabled: []const usize = &.{},
    selected: ?usize = 0,
    pressed: ?usize = null, // 菜单内按下的按钮编号。
    touchPress: ?window.touch.Capture = null,

    pub fn init(position: zhu.Vector2, menu: Menu) Menu {
        var result = menu;
        result.position = position;
        result.reset();
        return result;
    }

    // 选择第一个可用项，并清除点击交互状态。
    pub fn reset(self: *Menu) void {
        self.selected = null;
        self.down();
        self.pressed, self.touchPress = .{ null, null };
    }

    // 在默认游戏逻辑画面内居中，不受窗口像素尺寸变化影响。
    pub fn centerInWindow(self: *Menu) void {
        self.position = camera.size.sub(self.panel.size).scale(0.5);
    }

    pub fn update(self: *Menu, option: Option) ?u16 {
        const previous = self.selected;
        const clicked = self.updateTouch();

        const nav = option.nav orelse self.defaultNav();
        self.selectByNav(nav, option.wrap);

        if (nav.cancel) if (self.cancelEvent) |event| return event;

        if (nav.confirm) if (self.selected) |index| {
            if (!self.isDisabled(index)) {
                if (self.clickSound) |sound| audio.playSound(sound);
                return self.buttons[index].event;
            }
        };

        if (self.selected) |index| {
            if (index != previous) if (self.hoverSound) |sound| {
                audio.playSound(sound);
            };
        }

        const index = clicked orelse return null;
        if (self.clickSound) |sound| audio.playSound(sound);
        return self.buttons[index].event;
    }

    // 更新鼠标和触摸操作，返回本帧点击的按钮编号。
    fn updateTouch(self: *Menu) ?usize {
        const mouseMoved = window.mouse.moved;
        if (self.pressed) |index| active: {
            if (index >= self.buttons.len or self.isDisabled(index)) break :active;
            const press = &(self.touchPress orelse break :active);
            const shape = self.buttons[index].shape.move(self.position);
            const state = pressState(press, shape) orelse break :active;
            if (window.touch.moved or mouseMoved) self.selected = index;
            if (state == .held) return null;

            self.pressed, self.touchPress = .{ null, null };
            return if (self.trigger == .release) index else null;
        }
        self.pressed, self.touchPress = .{ null, null };

        var hover: ?usize = null;
        for (self.buttons, 0..) |button, index| {
            if (self.isDisabled(index)) continue;
            const shape = button.shape.move(self.position);
            if (hover == null and mouseMoved and window.mouse.hover(shape)) {
                hover = index;
            }

            var press = capturePress(shape) orelse continue;
            self.selected = index;
            const state = pressState(&press, shape);
            if (state == .held) {
                self.pressed, self.touchPress = .{ index, press };
            }
            const clicked = self.trigger == .press or state == .released;
            return if (clicked) index else null;
        }
        if (hover) |index| self.selected = index;
        return null;
    }

    /// 更新菜单，并将事件编号转为指定枚举。
    pub fn updateEnum(self: *Menu, E: type, option: Option) ?E {
        const event = self.update(option) orelse return null;
        const Tag = @typeInfo(E).@"enum".tag_type;
        return @fromBackingInt(zhu.toIndex(Tag, event));
    }

    fn defaultNav(self: Menu) Nav {
        const keys = self.navKeys;
        return switch (self.trigger) {
            .press => .{
                .up = window.key.anyPressed(keys.up),
                .down = window.key.anyPressed(keys.down),
                .confirm = window.key.anyPressed(keys.confirm),
                .cancel = window.key.anyPressed(keys.cancel),
            },
            .release => .{
                .up = window.key.anyReleased(keys.up),
                .down = window.key.anyReleased(keys.down),
                .confirm = window.key.anyReleased(keys.confirm),
                .cancel = window.key.anyReleased(keys.cancel),
            },
        };
    }

    pub fn draw(self: Menu) void {
        self.drawImage();
        self.drawText();
    }

    // 绘制遮罩、面板和按钮等非文字内容。
    pub fn drawImage(self: Menu) void {
        if (self.overlay) |overlay| {
            const rect: zhu.Rect = .init(.zero, camera.size);
            batch.drawRect(rect, .{ .color = overlay });
        }
        self.drawPanel();

        for (self.buttons, 0..) |button, index| {
            button.drawImage(self.buttonState(index), self.position);
        }
    }

    // 绘制标题和按钮文字，文字流水线由调用方设置。
    pub fn drawText(self: Menu) void {
        const title = self.title;
        if (title.text.len != 0) {
            const position = self.position.add(title.position);
            text.draw(title.text, position, title.option);
        }

        for (self.buttons, 0..) |button, index| {
            button.drawText(self.buttonState(index), self.position);
        }
    }

    pub fn drawLabel(self: Menu, index: usize, value: []const u8) void {
        var button = self.buttons[index];
        button.label = value;
        button.drawText(self.buttonState(index), self.position);
    }

    fn drawPanel(self: Menu) void {
        const rect = zhu.Rect.init(self.position, self.panel.size);
        if (self.panel.color) |color| {
            batch.drawRect(rect, .{ .color = color });
        }

        var image = assets.getImage(self.panel.image orelse return).?;
        if (self.panel.source) |source| image = image.sub(source);
        batch.drawImage(image, rect.min, .{ .size = rect.size });
    }

    pub fn buttonState(self: Menu, index: usize) Button.State {
        if (self.isDisabled(index)) return .disabled;

        const hover = self.selected == index;
        if (self.pressed) |pressed| {
            if (pressed == index and hover) return .pressed;
        }
        return if (hover) .hover else .normal;
    }

    fn isDisabled(self: Menu, index: usize) bool {
        for (self.disabled) |d| if (d == index) return true;
        return false;
    }

    fn selectByNav(self: *Menu, nav: Nav, wrap: bool) void {
        if (self.buttons.len == 0 or nav.up == nav.down) return;
        if (wrap) {
            if (nav.down) self.downWrap() else self.upWrap();
            return;
        }
        if (nav.down) self.down() else self.up();
    }

    fn up(self: *Menu) void {
        var index = self.selected orelse self.buttons.len;
        while (index > 0) {
            index -= 1;
            if (self.isDisabled(index)) continue;
            self.selected = index;
            return;
        }
    }

    fn down(self: *Menu) void {
        const start = if (self.selected) |v| v + 1 else 0;
        for (start..self.buttons.len) |index| {
            if (self.isDisabled(index)) continue;
            self.selected = index;
            return;
        }
    }

    fn upWrap(self: *Menu) void {
        var index = self.selected orelse 0;
        for (0..self.buttons.len) |_| {
            if (index == 0) index = self.buttons.len;
            index -= 1;
            if (self.isDisabled(index)) continue;
            self.selected = index;
            return;
        }
    }

    fn downWrap(self: *Menu) void {
        var index = self.selected orelse self.buttons.len - 1;
        for (0..self.buttons.len) |_| {
            index += 1;
            if (index == self.buttons.len) index = 0;
            if (self.isDisabled(index)) continue;
            self.selected = index;
            return;
        }
    }
};
