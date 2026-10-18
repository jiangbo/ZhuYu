const std = @import("std");
const input = @import("../input.zig");
const window = @import("../window.zig");
const camera = @import("../camera.zig");
const math = @import("../math.zig");
const batch = @import("../batch.zig");
const text = @import("../text.zig");
const Color = @import("../graphics.zig").Color;

// 按钮角色，实际绑定按键和显示文字可由游戏修改。
pub const Button = enum { enter, menu, extra, spare, up, left, right, down };

// 单个按钮配置，未指定按键、文字和形状时沿用默认值。
pub const Option = struct {
    button: Button,
    key: ?input.key.Code = null,
    label: ?[]const u8 = null, // 空切片表示不显示文字。
    shape: ?math.Shape = null, // 未指定时沿用默认布局。
    hidden: bool = false, // 同时控制输入和绘制，不修改形状。

    // 将菜单按钮改为返回键。
    pub const back: Option = .init(.menu, .ESCAPE, "返回");

    // 创建按钮、按键和文字配置，其余字段采用默认值。
    pub fn init(b: Button, key: input.key.Code, label: []const u8) Option {
        return .{ .button = b, .key = key, .label = label };
    }
};

// 按角色保存默认配置，避免外部依赖按钮排列顺序。
pub var defaults: std.EnumArray(Button, Option) = .init(.{
    .enter = .{ .button = .enter, .key = .F, .label = "确定" },
    .menu = .{ .button = .menu, .key = .E, .label = "菜单" },
    .extra = .{ .button = .extra, .key = .G, .label = "功能" },
    .spare = .{ .button = .spare, .hidden = true },
    .up = .{ .button = .up, .key = .UP, .label = "上" },
    .left = .{ .button = .left, .key = .LEFT, .label = "左" },
    .right = .{ .button = .right, .key = .RIGHT, .label = "右" },
    .down = .{ .button = .down, .key = .DOWN, .label = "下" },
});
// 最近一次更新使用的配置，绘制时保持不变。
var current: std.EnumArray(Button, Option) = undefined;
var hasPatch: bool = false; // 本轮更新前是否已经合入补丁。
// 每个按钮本次按住的键，null 表示未按住。
var pressedKeys: std.EnumArray(Button, ?input.key.Code) = .initFill(null);
pub var enabled: bool = false; // 统一控制虚拟按钮的输入与绘制。
var buttonCamera: camera.Camera = .window; // 输入和绘制共用 DPI 变换。

// 根据输入环境决定是否启用，并设置初始布局。
pub fn init() void {
    enabled = input.key.mayNotHave;
    layout();
    current = defaults;
    hasPatch = false;
}

// 相机统一处理 DPI，右侧按钮向窗口内侧留出握持空间。
fn layout() void {
    buttonCamera = .windowDpi();
    const size = buttonCamera.toWorld(window.rawSize);
    const confirm: math.Circle = .init(size.addXY(-80, -84), 38);
    // 菜单贴齐确定键的底边，功能键贴齐确定键的右边。
    const bottom = confirm.center.y + confirm.radius;
    const right = confirm.center.x + confirm.radius;
    const menuY = bottom - 26;
    const extraX = right - 26;
    const circles: std.EnumArray(Button, math.Circle) = .init(.{
        .enter = confirm,
        .menu = .init(.xy(size.x - 160, menuY), 26),
        .extra = .init(.xy(extraX, size.y - 168), 26),
        .spare = .init(size.addXY(-148, -156), 26),
        .up = .init(.xy(88, size.y - 148), 26),
        .left = .init(.xy(32, size.y - 92), 26),
        .right = .init(.xy(144, size.y - 92), 26),
        .down = .init(.xy(88, size.y - 36), 26),
    });
    for (&defaults.values, circles.values) |*option, circle| {
        option.shape = .{ .circle = circle };
    }
}

// 更新前逐个合入补丁，本轮首次调用时自动恢复默认配置。
pub fn patch(option: Option) void {
    if (!hasPatch) current = defaults;
    hasPatch = true;

    const value = current.getPtr(option.button);
    value.hidden = option.hidden;
    if (option.key) |key| value.key = key;
    if (option.label) |label| {
        value.label = if (label.len == 0) null else label;
    }
    if (option.shape) |shape| value.shape = shape;
}

// 未打补丁时自动恢复默认配置，暂存按钮变化供下一帧读取。
pub fn update() void {
    if (!enabled) return;
    if (window.resized) layout();
    if (!hasPatch) current = defaults;
    hasPatch = false;

    // 每个按住的触点只转换一次，汇总各按钮是否按住。
    var held: std.EnumArray(Button, bool) = .initFill(false);
    for (input.touch.points) |slot| {
        const point = slot orelse continue;
        if (point.state != .held) continue;
        const pos = buttonCamera.toWorld(point.raw);
        for (current.values, &held.values) |option, *down| {
            if (option.hidden) continue;
            const contains = option.shape.?.contains(pos);
            if (option.key != null and contains) down.* = true;
        }
    }

    // 首次按下时记录按键，松手、隐藏或取消绑定时释放原按键。
    const keys = &pressedKeys.values;
    for (current.values, held.values, keys) |option, down, *code| {
        if (down) {
            if (code.* != null) continue;

            const key = option.key.?;
            input.key.queue(key, true);
            code.* = key;
        } else if (code.*) |key| {
            input.key.queue(key, false);
            code.* = null;
        }
    }
}

// 淡出或停止更新界面前，暂存虚拟按键的释放。
pub fn reset() void {
    for (pressedKeys.values) |code| {
        if (code) |key| input.key.queue(key, false);
    }
    pressedKeys = .initFill(null);
}

// 启用时切换到全窗口视口，绘制形状的边框、填充和文字。
pub fn draw() void {
    if (!enabled) return;
    const size = window.rawSize;
    batch.useViewport(.init(.zero, size), size);
    defer batch.useViewport(window.viewRect, camera.size);
    camera.push(buttonCamera);
    defer camera.pop();

    drawImage();
    drawText();
}

// 遍历可见按钮，绘制边框和填充。
pub fn drawImage() void {
    for (current.values, pressedKeys.values) |option, code| {
        if (option.hidden) continue;
        drawShape(option.shape.?, code != null);
    }
}

// 根据按住状态选择颜色，绘制单个按钮的形状。
pub fn drawShape(shape: math.Shape, down: bool) void {
    // 普通与按住状态的边框色和填充色。
    const normalBorder = Color.rgba(1, 1, 1, 0.4);
    const pressedBorder = Color.rgba(0.65, 0.88, 1, 0.95);
    const normalFill = Color.rgba(0.06, 0.09, 0.13, 0.55);
    const pressedFill = Color.rgba(0.12, 0.42, 0.62, 0.85);
    const border = if (down) pressedBorder else normalBorder;
    const fill = if (down) pressedFill else normalFill;
    switch (shape) {
        .circle => |circle| {
            batch.drawCircle(circle.center, .{
                .size = .square(circle.radius * 2),
                .anchor = .center,
                .color = border,
            });
            batch.drawCircle(circle.center, .{
                .size = .square(circle.radius * 2 - 3),
                .anchor = .center,
                .color = fill,
            });
        },
        .rect => |rect| {
            batch.drawRect(rect, .{ .color = border });
            batch.drawRect(rect.pad(.square(1.5)), .{ .color = fill });
        },
    }
}

// 根据编译期选项切换 MSDF 管线，绘制按钮文字。
pub fn drawText() void {
    if (comptime text.useMsdf) text.msdf.begin();
    defer if (comptime text.useMsdf) text.msdf.end();

    for (current.values) |option| {
        if (option.hidden) continue;
        const label = option.label orelse continue;
        text.draw(label, option.shape.?.center(), .{
            .anchor = .center,
        });
    }
}
