const std = @import("std");

const window = @import("../window.zig");
const camera = @import("../camera.zig");
const zhu = @import("../zhu.zig");
const batch = @import("../batch.zig");
const text = @import("../text.zig");
const Color = @import("../graphics.zig").Color;

const touch = @This();

// 按钮角色，实际绑定按键和显示文字可由游戏修改。
pub const Button = enum { enter, menu, extra, spare, up, left, right, down };

// 单个按钮配置，未指定按键、文字和形状时沿用默认值。
pub const Option = struct {
    button: Button,
    key: ?window.key.Code = null,
    label: ?[]const u8 = null, // 空切片表示不显示文字。
    shape: ?zhu.Shape = null, // 未指定时沿用默认布局。
    hidden: bool = false, // 同时控制输入和绘制，不修改形状。

    // 将菜单按钮改为返回键。
    pub const back: Option = .init(.menu, .ESCAPE, "返回");

    // 创建按钮、按键和文字配置，其余字段采用默认值。
    pub fn init(b: Button, key: window.key.Code, label: []const u8) Option {
        return .{ .button = b, .key = key, .label = label };
    }
};

// 选择方向按钮或摇杆，两种模式都产生统一按键。
pub const Mode = enum { pad, stick };
var mode: Mode = undefined; // 当前使用的控件，由 init 设置。
var enabled: bool = false; // 统一控制当前模式的输入和绘制。

// 初始化指定模式，根据输入环境决定是否启用控件。
pub fn init(value: Mode) void {
    enabled = window.key.mayNotHave;
    initMode(value);
}

// 初始化指定模式的布局和按钮配置，不修改统一启用状态。
fn initMode(value: Mode) void {
    mode = value;
    switch (value) {
        .pad => {
            // 切回按钮模式时显式显示四个方向，再刷新当前配置。
            for ([_]pad.Button{ .up, .left, .right, .down }) |button| {
                pad.defaults.getPtr(button).hidden = false;
            }
            pad.init();
        },
        .stick => stick.init(),
    }
}

// 运行时切换模式，释放旧按键并保留控件的启用状态。
pub fn use(value: Mode) void {
    if (mode == value) return;
    reset();
    initMode(value);
}

// 关闭控件时释放按键，重复设置不产生额外操作。
pub fn setEnabled(value: bool) void {
    if (enabled and !value) reset();
    enabled = value;
}

// 更新当前控件，暂存按键变化供下一帧读取。
pub fn update() void {
    if (!enabled) return;
    switch (mode) {
        .pad => pad.update(),
        .stick => stick.update(),
    }
}

// 开始手柄绘制，切换到当前模式的窗口视口和相机。
pub fn begin() void {
    if (!enabled) return;
    beginControls();
}

// 结束手柄绘制，恢复进入前的视口和相机。
pub fn end() void {
    if (!enabled) return;
    endControls();
}

// 绘制当前模式的方向控件和共用功能按钮。
pub fn draw() void {
    begin();
    drawImage();
    drawText();
    end();
}

// 在手柄绘制范围内绘制当前模式的图形。
pub fn drawImage() void {
    if (!enabled) return;
    switch (mode) {
        .pad => pad.drawImage(),
        .stick => stick.drawImage(),
    }
}

// 在手柄绘制范围内绘制文字，流水线由调用方设置。
pub fn drawText() void {
    if (!enabled) return;
    drawButtonText();
}

// 场景切换或停止更新前，释放当前控件产生的按键。
pub fn reset() void {
    switch (mode) {
        .pad => pad.reset(),
        .stick => stick.reset(),
    }
}

// 方向按钮模式，可单独初始化、更新和绘制，与摇杆共享功能按钮。
pub const pad = struct {
    pub const Button = touch.Button;
    pub const Option = touch.Option;
    pub const patch = touch.patch;
    pub const init = initButtons;
    pub const update = updateButtons;
    pub const reset = resetButtons;
    pub const begin = beginControls;
    pub const end = endControls;
    pub const drawImage = drawButtons;
    pub const drawText = drawButtonText;
    pub const drawShape = touch.drawShape;

    pub fn draw() void {
        drawControls(@This());
    }

    // 按角色保存默认配置，避免外部依赖按钮排列顺序。
    pub var defaults: std.EnumArray(touch.Button, touch.Option) = .init(.{
        .enter = .{ .button = .enter, .key = .F, .label = "确定" },
        .menu = .{ .button = .menu, .key = .E, .label = "菜单" },
        .extra = .{ .button = .extra, .key = .G, .label = "功能" },
        .spare = .{ .button = .spare, .hidden = true },
        .up = .{ .button = .up, .key = .UP, .label = "上" },
        .left = .{ .button = .left, .key = .LEFT, .label = "左" },
        .right = .{ .button = .right, .key = .RIGHT, .label = "右" },
        .down = .{ .button = .down, .key = .DOWN, .label = "下" },
    });
};

// 最近一次更新使用的配置，绘制时保持不变。
var current: std.EnumArray(Button, Option) = undefined;
var hasPatch: bool = false; // 本轮更新前是否已经合入补丁。
// 每个按钮本次按住的键，null 表示未按住。
var pressedKeys: std.EnumArray(Button, ?window.key.Code) = .initFill(null);
var buttonCamera: camera.Camera = .window; // 输入和绘制共用 DPI 变换。

// 设置按钮的初始布局和当前配置。
fn initButtons() void {
    layoutButtons();
    current = pad.defaults;
    hasPatch = false;
}

// 相机统一处理 DPI，右侧按钮向窗口内侧留出握持空间。
fn layoutButtons() void {
    buttonCamera = .windowDpi();
    const size = buttonCamera.toWorld(window.size);
    const confirm: zhu.Circle = .init(size.addXY(-100, -84), 44);
    // 菜单贴齐确定键的底边，功能键贴齐确定键的右边。
    const bottom = confirm.center.y + confirm.radius;
    const right = confirm.center.x + confirm.radius;
    const menuY = bottom - 32;
    const extraX = right - 32;
    const circles: std.EnumArray(Button, zhu.Circle) = .init(.{
        .enter = confirm,
        // 与确定键的圆形边缘间距约 10。
        .menu = .init(.xy(size.x - 185.2, menuY), 32),
        .extra = .init(.xy(extraX, size.y - 169.2), 32),
        .spare = .init(size.addXY(-168, -156), 32),
        // 相邻方向按钮边缘间距约 20，保留左边距 6 和底边距 10。
        .up = .init(.xy(97.4, size.y - 160.8), 32),
        .left = .init(.xy(38, size.y - 101.4), 32),
        .right = .init(.xy(156.8, size.y - 101.4), 32),
        .down = .init(.xy(97.4, size.y - 42), 32),
    });
    for (&pad.defaults.values, circles.values) |*option, circle| {
        option.shape = .{ .circle = circle };
    }
}

// 更新前逐个合入补丁，本轮首次调用时自动恢复默认配置。
pub fn patch(option: Option) void {
    if (!hasPatch) current = pad.defaults;
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
fn updateButtons() void {
    if (window.resized) layoutButtons();
    if (!hasPatch) current = pad.defaults;
    hasPatch = false;

    // 每个按住的触点只转换一次，汇总各按钮是否按住。
    var held: std.EnumArray(Button, bool) = .initFill(false);
    for (window.touch.points) |slot| {
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
            window.key.queue(key, true);
            code.* = key;
        } else if (code.*) |key| {
            window.key.queue(key, false);
            code.* = null;
        }
    }
}

// 淡出或停止更新界面前，暂存虚拟按键的释放。
fn resetButtons() void {
    for (pressedKeys.values) |code| {
        if (code) |key| window.key.queue(key, false);
    }
    pressedKeys = .initFill(null);
}

// 切换到全窗口视口和按钮使用的 DPI 相机。
fn beginControls() void {
    batch.useViewport(.init(.zero, window.size), window.size);
    camera.push(buttonCamera);
}

// 恢复游戏视口和进入前的相机。
fn endControls() void {
    camera.pop();
    batch.useViewport(window.viewRect, camera.size);
}

// 两种控件共用视口、相机和文字绘制。
fn drawControls(comptime Control: type) void {
    beginControls();
    Control.drawImage();
    drawButtonText();
    endControls();
}

// 遍历可见按钮，绘制边框和填充。
fn drawButtons() void {
    for (current.values, pressedKeys.values) |option, code| {
        if (option.hidden) continue;
        drawShape(option.shape.?, code != null);
    }
}

// 根据按住状态选择颜色，绘制单个按钮的形状。
fn drawShape(shape: zhu.Shape, down: bool) void {
    // 黑白配色：普通状态为半透明黑底，按住时使用深灰底和明亮白边。
    const normalBorder = Color.gray(255, 102);
    const pressedBorder = Color.gray(255, 242);
    const normalFill = Color.gray(0, 166);
    const pressedFill = Color.gray(64, 242);
    const border = if (down) pressedBorder else normalBorder;
    const fill = if (down) pressedFill else normalFill;
    switch (shape) {
        .circle => |circle| {
            batch.drawCircle(circle.center, .{
                .size = .all(circle.radius * 2),
                .anchor = .center,
                .color = border,
            });
            batch.drawCircle(circle.center, .{
                .size = .all(circle.radius * 2 - 3),
                .anchor = .center,
                .color = fill,
            });
        },
        .rect => |rect| {
            batch.drawRect(rect, .{ .color = border });
            batch.drawRect(rect.pad(.all(1.5)), .{ .color = fill });
        },
    }
}

// 绘制按钮文字，文字流水线由调用方设置。
fn drawButtonText() void {
    for (current.values) |option| {
        if (option.hidden) continue;
        const label = option.label orelse continue;
        text.draw(label, option.shape.?.center(), .{
            .anchor = .center,
        });
    }
}

// 摇杆模式，可单独使用四方向按键或原始位移。
pub const stick = struct {
    // 功能按钮的配置、启用和按键状态统一由 pad 保存。
    pub const Option = touch.Option;
    pub const patch = touch.patch;
    pub const drawText = drawButtonText;
    pub const begin = beginControls;
    pub const end = endControls;

    // 摇杆启动区域，使用 DPI 坐标，布局默认设置为屏幕最左侧四分之一。
    pub var area: zhu.Rect = undefined;
    // 摇杆只跟踪一个触点，中心在本次操作中保持不变。
    var touchIndex: ?usize = null;
    var center: zhu.Vector2 = .zero;
    var offset: ?zhu.Vector2 = null; // 原始位移，null 表示没有摇杆操作。
    // 记录摇杆产生的上、下、左、右按键，只在状态变化时发送事件。
    var held: [4]bool = @splat(false);

    // 初始化时隐藏四个方向按钮，功能按钮交给 pad 处理。
    pub fn init() void {
        for ([_]pad.Button{ .up, .left, .right, .down }) |button| {
            pad.defaults.getPtr(button).hidden = true;
        }
        pad.init();
        layout();
    }

    // 根据窗口 DPI 设置摇杆启动区域。
    fn layout() void {
        const size = buttonCamera.toWorld(window.size);
        area = .init(.zero, .xy(size.x * 0.25, size.y));
    }

    // 更新功能按钮并返回摇杆原始位移，每帧与 update 二选一调用。
    pub fn updateOffset() ?zhu.Vector2 {
        pad.update();
        if (window.resized) layout();
        offset = updateStick();
        return offset;
    }

    // 更新摇杆和功能按钮，将位移转换为四方向按键，下一帧生效。
    // 每帧与 updateOffset 二选一调用，位移未超过 12 个界面单位时不触发方向键。
    pub fn update() void {
        const value = updateOffset() orelse zhu.Vector2.zero;
        const deadZone = 12; // 摇杆中心不触发方向键的范围，使用界面单位。
        // 只取偏移较大的轴，一次仅产生一个方向。
        const horizontal = @abs(value.x) > @abs(value.y);
        const down: [4]bool = .{
            !horizontal and value.y < -deadZone,
            !horizontal and value.y > deadZone,
            horizontal and value.x < -deadZone,
            horizontal and value.x > deadZone,
        };
        const keys = [_]window.key.Code{ .UP, .DOWN, .LEFT, .RIGHT };
        for (keys, down, &held) |key, pressed, *previous| {
            if (pressed == previous.*) continue;
            window.key.queue(key, pressed);
            previous.* = pressed;
        }
    }

    // 空闲时捕获区域内新按下的触点，之后持续跟踪同一槽位。
    fn updateStick() ?zhu.Vector2 {
        if (touchIndex) |index| {
            if (window.touch.points[index]) |point| {
                if (point.state == .held) {
                    return buttonCamera.toWorld(point.raw).sub(center);
                }
            }
            touchIndex = null;
            return null;
        }

        for (window.touch.points, 0..) |slot, index| {
            const point = slot orelse continue;
            if (!point.began or point.state != .held) continue;
            const start = buttonCamera.toWorld(point.start);
            if (!area.contains(start)) continue;

            touchIndex = index;
            center = start;
            return buttonCamera.toWorld(point.raw).sub(center);
        }
        return null;
    }

    // 场景切换前释放功能按键和摇杆产生的方向键，并结束摇杆操作。
    pub fn reset() void {
        pad.reset();
        const keys = [_]window.key.Code{ .UP, .DOWN, .LEFT, .RIGHT };
        for (keys, held) |key, down| if (down) window.key.queue(key, false);

        held = @splat(false);
        touchIndex = null;
        offset = null;
    }

    // 在窗口坐标下绘制图形和文字。
    pub fn draw() void {
        drawControls(@This());
    }

    // 复用 pad 绘制功能按钮，操作时额外绘制浮动摇杆。
    pub fn drawImage() void {
        pad.drawImage();
        const value = offset orelse return;
        // 先用长度平方判断越界，仅越界时开根号，输入仍保留原始位移。
        var shift = value;
        const len2 = value.length2();
        if (len2 > 56 * 56) shift = value.scale(56 / @sqrt(len2));
        pad.drawShape(.{ .circle = .init(center, 56) }, false);
        pad.drawShape(.{ .circle = .init(center.add(shift), 26) }, true);
    }
};
