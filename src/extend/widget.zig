const input = @import("../input.zig");
const camera = @import("../camera.zig");
const math = @import("../math.zig");
const batch = @import("../batch.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const audio = @import("../audio.zig");
const assets = @import("../assets.zig");

const Vector2 = math.Vector2;

// 默认按钮使用 usize 事件编号。
pub const Button = ButtonT(usize);

// 事件类型由调用方决定，提供按钮配置和绘制。
pub fn ButtonT(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const State = enum { normal, hover, pressed, disabled };
        pub const Style = struct {
            color: ?graphics.Color = null,
            image: ?graphics.ImageId = null,
            source: ?math.Rect = null,
            text: text.Option = .{},
        };

        shape: math.Shape, // 命中和绘制共用的矩形或圆形区域。
        event: T,
        label: []const u8 = "",
        patch: ?graphics.NineImage.Patch = null,
        normal: Style = .{},
        hover: Style = .{},
        pressed: Style = .{},
        disabled: Style = .{},

        // 根据状态返回对应样式。
        pub fn style(self: Self, state: State) Style {
            return switch (state) {
                .normal => self.normal,
                .hover => self.hover,
                .pressed => self.pressed,
                .disabled => self.disabled,
            };
        }

        // 根据形状绘制背景，并在区域内绘制图片。
        pub fn drawImage(self: Self, state: State, offset: Vector2) void {
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
        pub fn drawText(self: Self, state: State, offset: Vector2) void {
            if (self.label.len == 0) return;
            var option = self.style(state).text;
            const position = self.shape.center().add(offset);
            if (option.anchor == null) option.anchor = .center;
            text.draw(self.label, position, option);
        }
    };
}

// 单个区域的点击状态，供游戏中的独立按钮使用。
pub const Click = struct {
    pressed: bool = false, // 是否已在区域内按下，且尚未取消或释放。

    // 每帧调用一次，区域内按下并释放才算点击。
    // 移出或取消即失效，再移回也不恢复。
    pub fn update(self: *Click, rect: math.Rect) bool {
        const state = input.touch.query(rect);
        if (state.pressed) self.pressed = true;

        const clicked = self.pressed and state.released;
        if (!state.held) self.pressed = false;
        return clicked;
    }
};

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

// 默认菜单使用 usize 事件编号。
pub const Menu = MenuT(usize);

// 按事件类型生成菜单，选中项和导航仍使用按钮下标。
pub fn MenuT(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Trigger = enum { press, release };

        pub const Nav = struct {
            pub const none: Nav = .{};

            up: bool = false,
            down: bool = false,
            confirm: bool = false,
            cancel: bool = false,
        };

        pub const NavKeys = struct {
            up: []const input.key.Code = &.{ .UP, .W },
            down: []const input.key.Code = &.{ .DOWN, .S },
            confirm: []const input.key.Code = &.{ .ENTER, .SPACE, .F },
            cancel: []const input.key.Code = &.{.ESCAPE},
        };

        pub const Option = struct {
            nav: ?Nav = null,
            wrap: bool = true,
        };

        position: math.Vector2 = .zero,
        overlay: ?graphics.Color = null,
        panel: struct {
            size: math.Vector2 = .zero,
            color: ?graphics.Color = null,
            image: ?graphics.ImageId = null,
            source: ?math.Rect = null,
        } = .{},
        title: struct {
            text: []const u8 = "",
            position: math.Vector2 = .zero,
            option: text.Option = .{ .anchor = .center },
        } = .{},
        buttons: []const ButtonT(T) = &.{},
        // 键盘导航、鼠标和触摸点击共用的触发时机。
        trigger: Trigger = .release,
        navKeys: NavKeys = .{},
        cancelEvent: ?T = null,
        hoverSound: ?[:0]const u8 = null,
        clickSound: ?[:0]const u8 = null,
        disabled: []const usize = &.{},
        selected: ?usize = 0,
        pressed: ?usize = null, // 菜单内按下的按钮编号。

        pub fn init(position: math.Vector2, menu: Self) Self {
            var result = menu;
            result.position = position;
            result.reset();
            return result;
        }

        // 选择第一个可用项，并清除点击交互状态。
        pub fn reset(self: *Self) void {
            self.selected = null;
            self.down();
            self.pressed = null;
        }

        // 在默认游戏逻辑画面内居中，不受窗口像素尺寸变化影响。
        pub fn centerInWindow(self: *Self) void {
            self.position = camera.size.sub(self.panel.size).scale(0.5);
        }

        pub fn update(self: *Self, option: Option) ?T {
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
        fn updateTouch(self: *Self) ?usize {
            const moved = input.mouse.moved or input.touch.moved;

            var hover: ?usize = null; // 鼠标悬停的按钮。
            var touched: ?usize = null; // 触摸或鼠标左键当前所在的按钮。
            var newPressed: ?usize = null; // 本帧按下的按钮，取第一个。
            // 保存按下按钮的查询结果，禁用的按钮保持空状态。
            var state: input.touch.State = .{};
            for (self.buttons, 0..) |button, index| {
                if (self.isDisabled(index)) continue;
                const shape = button.shape.move(self.position);
                const press = input.touch.query(shape);
                // 当前按钮内正按住或刚释放。
                if (hover == null and input.mouse.hover(shape)) hover = index;
                const active = press.held or press.released;
                if (touched == null and active) touched = index;

                if (newPressed != null) continue; // 已找到本帧按下的按钮
                if (self.pressed == index or press.pressed) state = press;
                if (press.pressed) newPressed = index;
            }

            if (newPressed) |index| self.pressed = index;
            const clicked = switch (self.trigger) {
                .press => newPressed,
                .release => if (state.released) self.pressed else null,
            };
            if (state.released or !state.held) self.pressed = null;

            if (moved) {
                if (touched orelse hover) |index| self.selected = index;
            }
            return clicked;
        }

        /// 更新菜单，并将整数或枚举事件转为指定枚举。
        pub fn updateEnum(self: *Self, E: type, option: Option) ?E {
            const event = self.update(option) orelse return null;
            const Tag = @typeInfo(E).@"enum".tag_type;
            return @fromBackingInt(math.toIndex(Tag, event));
        }

        fn defaultNav(self: Self) Nav {
            const keys = self.navKeys;
            return switch (self.trigger) {
                .press => .{
                    .up = input.key.anyPressed(keys.up),
                    .down = input.key.anyPressed(keys.down),
                    .confirm = input.key.anyPressed(keys.confirm),
                    .cancel = input.key.anyPressed(keys.cancel),
                },
                .release => .{
                    .up = input.key.anyReleased(keys.up),
                    .down = input.key.anyReleased(keys.down),
                    .confirm = input.key.anyReleased(keys.confirm),
                    .cancel = input.key.anyReleased(keys.cancel),
                },
            };
        }

        pub fn draw(self: Self) void {
            self.drawImage();
            self.drawText();
        }

        // 绘制遮罩、面板和按钮等非文字内容。
        pub fn drawImage(self: Self) void {
            if (self.overlay) |overlay| {
                const rect: math.Rect = .init(.zero, camera.size);
                batch.drawRect(rect, .{ .color = overlay });
            }
            self.drawPanel();

            for (self.buttons, 0..) |button, index| {
                button.drawImage(self.buttonState(index), self.position);
            }
        }

        // 绘制标题和按钮文字，文字流水线由调用方设置。
        pub fn drawText(self: Self) void {
            const title = self.title;
            if (title.text.len != 0) {
                const position = self.position.add(title.position);
                text.draw(title.text, position, title.option);
            }

            for (self.buttons, 0..) |button, index| {
                button.drawText(self.buttonState(index), self.position);
            }
        }

        pub fn drawLabel(self: Self, index: usize, value: []const u8) void {
            var button = self.buttons[index];
            button.label = value;
            button.drawText(self.buttonState(index), self.position);
        }

        fn drawPanel(self: Self) void {
            const rect = math.Rect.init(self.position, self.panel.size);
            if (self.panel.color) |color| {
                batch.drawRect(rect, .{ .color = color });
            }

            var image = assets.getImage(self.panel.image orelse return).?;
            if (self.panel.source) |source| image = image.sub(source);
            batch.drawImage(image, rect.min, .{ .size = rect.size });
        }

        pub fn buttonState(self: Self, index: usize) ButtonT(T).State {
            if (self.isDisabled(index)) return .disabled;

            const hover = self.selected == index;
            if (self.pressed) |pressed| {
                if (pressed == index and hover) return .pressed;
            }
            return if (hover) .hover else .normal;
        }

        fn isDisabled(self: Self, index: usize) bool {
            for (self.disabled) |d| if (d == index) return true;
            return false;
        }

        fn selectByNav(self: *Self, nav: Nav, wrap: bool) void {
            if (self.buttons.len == 0 or nav.up == nav.down) return;
            if (wrap) {
                if (nav.down) self.downWrap() else self.upWrap();
                return;
            }
            if (nav.down) self.down() else self.up();
        }

        fn up(self: *Self) void {
            var index = self.selected orelse self.buttons.len;
            while (index > 0) {
                index -= 1;
                if (self.isDisabled(index)) continue;
                self.selected = index;
                return;
            }
        }

        fn down(self: *Self) void {
            const start = if (self.selected) |v| v + 1 else 0;
            for (start..self.buttons.len) |index| {
                if (self.isDisabled(index)) continue;
                self.selected = index;
                return;
            }
        }

        fn upWrap(self: *Self) void {
            var index = self.selected orelse 0;
            for (0..self.buttons.len) |_| {
                if (index == 0) index = self.buttons.len;
                index -= 1;
                if (self.isDisabled(index)) continue;
                self.selected = index;
                return;
            }
        }

        fn downWrap(self: *Self) void {
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
}
