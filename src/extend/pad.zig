const input = @import("../input.zig");
const window = @import("../window.zig");
const camera = @import("../camera.zig");
const math = @import("../math.zig");
const batch = @import("../batch.zig");
const text = @import("../text.zig");
const Color = @import("../graphics.zig").Color;

// 单个按钮配置，未指定按键、文字和形状时沿用默认值。
pub const Option = struct {
    index: usize,
    key: ?input.key.Code = null,
    label: ?[]const u8 = null, // 空切片表示不显示文字。
    shape: ?math.Shape = null,
    hidden: bool = false,
};

// 右侧依次为确定、菜单、功能和帮助，默认形状由布局设置。
pub var defaults: [8]Option = .{
    .{ .index = 0, .key = .UP, .label = "上" },
    .{ .index = 1, .key = .LEFT, .label = "左" },
    .{ .index = 2, .key = .RIGHT, .label = "右" },
    .{ .index = 3, .key = .DOWN, .label = "下" },
    .{ .index = 4, .key = .F, .label = "确定" },
    .{ .index = 5, .key = .E, .label = "菜单" },
    .{ .index = 6, .key = .G, .label = "调试" },
    .{ .index = 7, .key = .H, .label = "帮助" },
};
// 更新恢复默认值，绘制直接使用。
var current: [defaults.len]Option = undefined;
// 每个按钮本次按住的键，null 表示未按住。
var pressedKeys: [defaults.len]?input.key.Code = @splat(null);
pub var enabled: bool = false; // 统一控制虚拟按钮的输入与绘制。
var buttonCamera: camera.Camera = .window; // 输入和绘制共用 DPI 变换。

// 根据输入环境决定是否启用，并设置初始布局。
pub fn init() void {
    enabled = input.key.mayNotHave;
    layout();
    @memcpy(&current, &defaults);
}

// 相机统一处理 DPI，右侧按钮向窗口内侧留出握持空间。
fn layout() void {
    buttonCamera = .windowDpi();
    const size = buttonCamera.toWorld(window.rawSize);
    defaults[0].shape = .{ .circle = .init(.xy(88, size.y - 148), 26) };
    defaults[1].shape = .{ .circle = .init(.xy(32, size.y - 92), 26) };
    defaults[2].shape = .{ .circle = .init(.xy(144, size.y - 92), 26) };
    defaults[3].shape = .{ .circle = .init(.xy(88, size.y - 36), 26) };
    defaults[4].shape = .{ .circle = .init(size.addXY(-80, -84), 38) };
    // 菜单贴齐确定键的底边，功能键贴齐确定键的右边。
    const confirm = defaults[4].shape.?.circle;
    const bottom = confirm.center.y + confirm.radius;
    const right = confirm.center.x + confirm.radius;
    const menuY = bottom - 26;
    const extraX = right - 26;
    defaults[5].shape = .{ .circle = .init(.xy(size.x - 160, menuY), 26) };
    defaults[6].shape = .{ .circle = .init(.xy(extraX, size.y - 168), 26) };
    defaults[7].shape = .{ .circle = .init(size.addXY(-148, -156), 26) };
}

// 更新布局和配置，再处理按钮的按键状态变化。
pub fn update(options: []const Option) void {
    if (!enabled) return;
    if (window.resized) layout();
    mergeOptions(options);

    // 首次按下时记录按键，持续按住时保留，松手或隐藏时释放。
    for (current, &pressedKeys) |option, *code| {
        const down = if (option.shape) |shape|
            input.touch.queryDpi(shape).held
        else
            false;

        if (down) {
            if (code.* != null) continue;

            const key = option.key.?;
            input.key.set(key, true);
            code.* = key;
        } else if (code.*) |key| {
            input.key.set(key, false);
            code.* = null;
        }
    }
}

// 恢复默认配置，合入本次修改，并清空隐藏按钮的形状。
fn mergeOptions(options: []const Option) void {
    @memcpy(&current, &defaults);
    for (options) |option| {
        const value = &current[option.index];
        value.hidden = option.hidden;
        if (option.key) |key| value.key = key;
        if (option.label) |label| {
            value.label = if (label.len == 0) null else label;
        }
        if (option.shape) |shape| value.shape = shape;
    }
    for (&current) |*option| {
        if (option.hidden) option.shape = null;
    }
}

// 淡出或停止更新界面前，释放虚拟按键。
pub fn reset() void {
    for (pressedKeys) |code| {
        if (code) |key| input.key.set(key, false);
    }
    pressedKeys = @splat(null);
}

// 启用时切换到全窗口视口，绘制形状的边框、填充和文字。
pub fn draw() void {
    if (!enabled) return;
    const size = window.rawSize;
    batch.useViewport(.init(.zero, size), size);
    camera.push(buttonCamera);
    defer camera.pop();

    drawImage();
    drawText();
}

// 遍历可见按钮，绘制边框和填充。
pub fn drawImage() void {
    for (current, pressedKeys) |option, code| {
        const shape = option.shape orelse continue;
        drawShape(shape, code != null);
    }
}

// 根据按住状态选择颜色，绘制单个按钮的形状。
fn drawShape(shape: math.Shape, down: bool) void {
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

    for (current) |option| {
        const shape = option.shape orelse continue;
        const label = option.label orelse continue;
        text.draw(label, shape.center(), .{
            .anchor = .center,
        });
    }
}
