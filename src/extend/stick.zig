const input = @import("../input.zig");
const window = @import("../window.zig");
const camera = @import("../camera.zig");
const math = @import("../math.zig");
const batch = @import("../batch.zig");
const pad = @import("pad.zig");

// 功能按钮的配置、启用和按键状态统一由 pad 保存。
pub const Option = pad.Option;
pub const patch = pad.patch;
pub const drawText = pad.drawText;

// 摇杆启动区域，使用 DPI 坐标，布局默认设置为左下四分之一屏幕。
pub var area: math.Rect = undefined;
var stickCamera: camera.Camera = .window; // 摇杆输入和绘制共用 DPI 变换。
// 摇杆只跟踪一个触点，中心在本次操作中保持不变。
var touchIndex: ?usize = null;
var center: math.Vector2 = .zero;
var offset: ?math.Vector2 = null; // 原始位移，null 表示没有摇杆操作。

// 初始化时隐藏方向按钮，功能按钮交给 pad 处理。
pub fn init() void {
    for ([_]pad.Button{ .up, .left, .right, .down }) |button| {
        pad.defaults.getPtr(button).hidden = true;
    }
    pad.init();
    layout();
}

// 根据窗口 DPI 设置摇杆启动区域。
fn layout() void {
    stickCamera = .windowDpi();
    const size = stickCamera.toWorld(window.rawSize);
    area = .init(.xy(0, size.y * 0.5), size.scale(0.5));
}

// 更新 pad 的功能按钮，再计算摇杆位移。
pub fn update() ?math.Vector2 {
    if (!pad.enabled) return null;
    pad.update();
    if (window.resized) layout();
    offset = updateStick();
    return offset;
}

// 空闲时捕获区域内新按下的触点，之后持续跟踪同一槽位。
fn updateStick() ?math.Vector2 {
    if (touchIndex) |index| {
        if (input.touch.points[index]) |point| {
            if (point.state == .held) {
                return stickCamera.toWorld(point.raw).sub(center);
            }
        }
        touchIndex = null;
        return null;
    }

    for (input.touch.points, 0..) |slot, index| {
        const point = slot orelse continue;
        if (!point.began or point.state != .held) continue;
        const start = stickCamera.toWorld(point.start);
        if (!area.contains(start)) continue;

        touchIndex = index;
        center = start;
        return stickCamera.toWorld(point.raw).sub(center);
    }
    return null;
}

// 场景切换前释放功能按键，并结束摇杆操作。
pub fn reset() void {
    pad.reset();
    touchIndex = null;
    offset = null;
}

// 在窗口 DPI 坐标下绘制浮动摇杆和功能键盘。
pub fn draw() void {
    if (!pad.enabled) return;
    const size = window.rawSize;
    batch.useViewport(.init(.zero, size), size);
    defer batch.useViewport(window.viewRect, camera.size);
    camera.push(stickCamera);
    defer camera.pop();

    drawImage();
    drawText();
}

// 复用 pad 绘制功能按钮，操作时额外绘制浮动摇杆。
pub fn drawImage() void {
    pad.drawImage();
    if (offset) |value| {
        pad.drawShape(.{ .circle = .init(center, 56) }, false);
        pad.drawShape(.{ .circle = .init(center.add(value), 26) }, true);
    }
}
