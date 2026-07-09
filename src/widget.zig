const std = @import("std");

const input = @import("input.zig");
const window = @import("window.zig");
const math = @import("math.zig");
const batch = @import("batch.zig");
const graphics = @import("graphics.zig");
const text = @import("text.zig");
const audio = @import("audio.zig");
const assets = @import("assets.zig");

const Vector2 = math.Vector2;

pub const Button = struct {
    pub const State = enum { normal, hover, pressed, disabled };
    pub const Style = struct {
        image: ?graphics.ImageId = null,
        source: ?math.Rect = null,
        text: text.Option = .{},
    };

    rect: math.Rect,
    event: usize,
    label: []const u8 = "",
    patch: ?graphics.NineImage.Patch = null,
    normal: Style = .{},
    hover: Style = .{},
    pressed: Style = .{},
    disabled: Style = .{},

    /// 根据状态返回对应样式
    pub fn style(self: Button, state: State) Style {
        return switch (state) {
            .normal => self.normal,
            .hover => self.hover,
            .pressed => self.pressed,
            .disabled => self.disabled,
        };
    }

    /// 绘制按钮背景图
    pub fn drawImage(self: Button, state: State, offset: Vector2) void {
        const visual = self.style(state);
        var image = assets.getImage(visual.image orelse return).?;
        if (visual.source) |source| image = image.sub(source);

        const rect = self.rect.move(offset);
        if (self.patch) |patch| {
            return batch.drawNine(.init(image, patch), rect);
        }
        batch.drawImage(image, rect.min, .{ .size = rect.size });
    }

    /// 绘制按钮文字
    pub fn drawText(self: Button, state: State, offset: Vector2) void {
        if (self.label.len == 0) return;

        var option = self.style(state).text;
        const rect = self.rect.move(offset);
        if (option.anchor == null) option.anchor = .center;
        text.draw(self.label, rect.center(), option);
    }
};

pub fn ClickT(comptime T: type) type {
    return struct {
        hover: ?T = null,
        pressed: ?T = null,
        captured: bool = false,
        frame: u64 = 0,

        pub const empty: @This() = .{};

        pub fn update(self: *@This(), hover: ?T) ?T {
            const currentFrame = window.frameCount();
            if (self.frame + 1 < currentFrame) self.* = .empty;
            self.frame = currentFrame;

            self.hover = hover;
            self.captured = self.hover != null or self.pressed != null;

            if (hover) |value| {
                if (input.mouse.pressed(.LEFT)) self.pressed = value;
            }

            if (!input.mouse.released(.LEFT)) return null;
            defer self.pressed = null;
            if (!std.meta.eql(self.pressed, self.hover)) return null;
            return self.hover;
        }
    };
}
pub const Click = ClickT(usize);

pub const Popup = struct {
    anchor: Vector2,
    size: Vector2, // 实际尺寸：贴边定位 + clamp
    maxSize: ?Vector2 = null, // 翻转判断用的最大预期尺寸，缺省用 size
    offset: Vector2 = .zero,
    bounds: ?Vector2 = null,
};

pub fn popupPosition(popup: Popup) Vector2 {
    const bounds = popup.bounds orelse window.size;
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

pub fn StackT(T: type) type {
    return struct {
        item: T,
        count: u32,

        pub const empty: @This() = .{ .item = undefined, .count = 0 };
        pub fn one(item: T) @This() {
            return .{ .item = item, .count = 1 };
        }
    };
}

pub fn StackStore(T: type, len: usize, limitOf: fn (T) u32) type {
    return struct {
        pub const Stack = StackT(T);
        pub const Put = struct {
            subs: []const Stack = &.{},
            adds: []const Stack = &.{},
        };
        pub const Entry = struct {
            index: usize,
            item: T,
            count: u32,

            pub fn init(index: usize, item: T, count: u32) Entry {
                return .{ .index = index, .item = item, .count = count };
            }
        };
        pub const Patch = union(enum) { add: Entry, sub: Entry };
        pub const Move = enum { merge, clear, swap };
        pub const Done = struct { ok: bool, patches: []const Patch };
        const Try = struct {
            buffer: ?*std.ArrayList(Patch) = null,
            items: []const Stack,
        };

        stacks: [len]Stack = @splat(.empty),

        pub fn add(self: *@This(), item: T, count: u32) u32 {
            const args: Stack = .{ .item = item, .count = count };
            return self.tryAdd(.{ .items = &.{args} }) catch unreachable;
        }

        pub fn sub(self: *@This(), item: T, count: u32) u32 {
            const args: Stack = .{ .item = item, .count = count };
            return self.trySub(.{ .items = &.{args} }) catch unreachable;
        }

        pub fn addAll(self: *@This(), item: T, count: u32) bool {
            var patches: [len + 1]Patch = undefined;

            const args: Stack = .{ .item = item, .count = count };
            const done = self.put(&patches, .{ .adds = &.{args} });
            if (done.ok) return true;

            self.rollback(done.patches);
            return false;
        }

        pub fn subAll(self: *@This(), item: T, count: u32) bool {
            var patches: [len + 1]Patch = undefined;

            const args: Stack = .{ .item = item, .count = count };
            const done = self.put(&patches, .{ .subs = &.{args} });
            if (done.ok) return true;

            self.rollback(done.patches);
            return false;
        }

        pub fn get(self: *@This(), index: usize) ?Stack {
            return if (self.getPtr(index)) |ptr| ptr.* else null;
        }

        pub fn getPtr(self: *@This(), index: usize) ?*Stack {
            if (self.stacks[index].count == 0) return null;
            return &self.stacks[index];
        }

        pub fn first(self: *const @This(), item: T) ?usize {
            for (&self.stacks, 0..) |*stack, index| {
                if (stack.count == 0) continue;
                if (std.meta.eql(stack.item, item)) return index;
            }
            return null;
        }

        pub fn firstEmpty(self: *const @This()) ?usize {
            for (self.stacks, 0..) |*stack, index| {
                if (stack.count == 0) return index;
            }
            return null;
        }

        pub fn clearAt(self: *@This(), index: usize) void {
            self.stacks[index].count = 0;
        }

        pub fn clear(self: *@This()) void {
            for (&self.stacks) |*stack| stack.count = 0;
        }

        pub fn move(self: *@This(), from: usize, to: usize) ?Move {
            if (from == to) return null;

            const source = &self.stacks[from];
            const target = &self.stacks[to];
            if (source.count == 0) return null;
            const empty = target.count == 0;
            if (empty or !std.meta.eql(source.item, target.item)) {
                std.mem.swap(Stack, source, target);
                return .swap;
            }

            const limit = limitOf(source.item);
            std.debug.assert(limit > 0);
            if (target.count >= limit) return null;

            const moved = @min(limit - target.count, source.count);
            target.count += moved;
            source.count -= moved;
            return if (source.count > 0) .merge else .clear;
        }

        pub fn tryPut(self: *@This(), buf: []Patch, ops: Put) !Done {
            var buffer = std.ArrayList(Patch).initBuffer(buf);
            errdefer self.rollback(buffer.items);

            var args: Try = .{ .buffer = &buffer, .items = ops.subs };
            const subLeft = try self.trySub(args);
            args = .{ .buffer = &buffer, .items = ops.adds };
            const addLeft = try self.tryAdd(args);
            const ok = subLeft == 0 and addLeft == 0;
            return .{ .ok = ok, .patches = buffer.items };
        }

        pub fn put(self: *@This(), buf: []Patch, ops: Put) Done {
            return self.tryPut(buf, ops) catch @panic("buffer too small");
        }

        pub fn rollback(self: *@This(), patches: []const Patch) void {
            var iterator = std.mem.reverseIterator(patches);
            while (iterator.next()) |patch| {
                switch (patch) {
                    .add => |entry| self.putOne(.{ .sub = entry }),
                    .sub => |entry| self.putOne(.{ .add = entry }),
                }
            }
        }

        fn addOne(self: *@This(), args: Stack) ?Entry {
            const limit = limitOf(args.item);
            std.debug.assert(limit > 0);

            if (limit > 1) if (self.merge(args, limit)) |e| return e;
            return self.fill(args, limit);
        }

        fn trySub(self: *@This(), args: Try) !u32 {
            var left: u32 = 0;
            for (args.items) |entry| {
                if (entry.count == 0) continue;

                var remaining = entry.count;
                for (&self.stacks, 0..) |*stack, index| {
                    if (remaining == 0) break;
                    if (stack.count == 0) continue;
                    if (!std.meta.eql(stack.item, entry.item)) continue;

                    const count = @min(stack.count, remaining);
                    const patch = Entry.init(index, stack.item, count);
                    stack.count -= count;
                    errdefer stack.count += count;
                    if (args.buffer) |buffer|
                        try buffer.appendBounded(.{ .sub = patch });
                    remaining -= count;
                }
                left += remaining;
            }
            return left;
        }

        fn tryAdd(self: *@This(), args: Try) !u32 {
            var left: u32 = 0;
            for (args.items) |entry| {
                var remaining = entry;
                while (remaining.count > 0) {
                    const one = self.addOne(remaining) orelse break;
                    errdefer self.putOne(.{ .sub = one });
                    if (args.buffer) |buffer|
                        try buffer.appendBounded(.{ .add = one });
                    remaining.count -= one.count;
                }
                left += remaining.count;
            }
            return left;
        }

        pub fn subAt(self: *@This(), index: usize, count: u32) ?Entry {
            std.debug.assert(count > 0);
            const stack = self.getPtr(index) orelse return null;
            if (stack.count < count) return null;

            const entry = Entry.init(index, stack.item, count);
            stack.count -= count;
            return entry;
        }

        pub fn useAt(self: *@This(), index: usize, count: Stack) bool {
            var patches: [len + 1]Patch = undefined;
            var buffer = std.ArrayList(Patch).initBuffer(&patches);

            const taken = self.subAt(index, 1) orelse return false;
            buffer.appendAssumeCapacity(.{ .sub = taken });
            const args: Try = .{ .buffer = &buffer, .items = &.{count} };
            const left = self.tryAdd(args) catch @panic("buffer too small");
            if (left == 0) return true;

            self.rollback(buffer.items);
            return false;
        }

        fn merge(self: *@This(), args: Stack, limit: u32) ?Entry {
            for (0..self.stacks.len) |index| {
                const stack = self.getPtr(index) orelse continue;
                if (!std.meta.eql(stack.item, args.item)) continue;
                if (stack.count >= limit) continue;

                const moved = @min(limit - stack.count, args.count);
                stack.count += moved;
                return .init(index, args.item, moved);
            }
            return null;
        }

        fn fill(self: *@This(), args: Stack, limit: u32) ?Entry {
            for (&self.stacks, 0..) |*stack, index| {
                if (stack.count != 0) continue;

                const moved = @min(limit, args.count);
                stack.* = .{ .item = args.item, .count = moved };
                return .init(index, args.item, moved);
            }
            return null;
        }

        fn putOne(self: *@This(), patch: Patch) void {
            switch (patch) {
                .add => |entry| {
                    const stack = &self.stacks[entry.index];
                    if (stack.count == 0) stack.item = entry.item;
                    std.debug.assert(std.meta.eql(entry.item, stack.item));
                    stack.count += entry.count;
                },
                .sub => |entry| {
                    const taken = self.subAt(entry.index, entry.count).?;
                    std.debug.assert(std.meta.eql(entry.item, taken.item));
                },
            }
        }
    };
}

pub const Menu = struct {
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
    buttons: []const Button = &.{},
    navKeys: NavKeys = .{},
    cancelEvent: ?usize = null,
    hoverSound: ?[:0]const u8 = null,
    clickSound: ?[:0]const u8 = null,
    disabled: []const usize = &.{},
    selected: ?usize = null,
    click: Click = .empty,

    pub fn init(position: math.Vector2, menu: Menu) Menu {
        var result = menu;
        result.position = position;
        result.selected = null;
        result.click = .empty;
        return result;
    }

    pub fn centerInWindow(self: *Menu) void {
        self.position = window.size.sub(self.panel.size).scale(0.5);
    }

    pub fn update(self: *Menu, option: Option) ?usize {
        const previous = self.selected;
        const hover = self.mouseHover();

        if (input.mouse.changed) {
            const touched = hover != null or self.click.hover != null;
            if (touched) self.selected = hover;
        }

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

        const index = self.click.update(hover) orelse return null;
        if (self.clickSound) |sound| audio.playSound(sound);
        return self.buttons[index].event;
    }

    fn defaultNav(self: Menu) Nav {
        const keys = self.navKeys;
        return .{
            .up = input.key.anyPressed(keys.up),
            .down = input.key.anyPressed(keys.down),
            .confirm = input.key.anyPressed(keys.confirm),
            .cancel = input.key.anyPressed(keys.cancel),
        };
    }

    fn mouseHover(self: Menu) ?usize {
        for (self.buttons, 0..) |button, index| {
            if (self.isDisabled(index)) continue;
            const rect = button.rect.move(self.position);
            if (rect.contains(window.mouse)) return index;
        }
        return null;
    }

    pub fn draw(self: Menu) void {
        if (self.overlay) |overlay| {
            const rect: math.Rect = .init(.zero, window.size);
            batch.drawRect(rect, .{ .color = overlay });
        }
        self.drawPanel();

        for (self.buttons, 0..) |button, index| {
            button.drawImage(self.buttonState(index), self.position);
        }

        const title = self.title;
        if (title.text.len != 0) {
            const position = self.position.add(title.position);
            text.draw(title.text, position, title.option);
        }

        for (self.buttons, 0..) |button, index| {
            button.drawText(self.buttonState(index), self.position);
        }
    }

    pub fn drawText(self: Menu, index: usize, value: []const u8) void {
        var button = self.buttons[index];
        button.label = value;
        button.drawText(self.buttonState(index), self.position);
    }

    fn drawPanel(self: Menu) void {
        const rect = math.Rect.init(self.position, self.panel.size);
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
        if (self.click.pressed) |pressed| {
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
