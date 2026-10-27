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

// 摇杆启动区域，使用 DPI 坐标，布局默认设置为屏幕最左侧四分之一。
pub var area: math.Rect = undefined;
var stickCamera: camera.Camera = .window; // 摇杆输入和绘制共用 DPI 变换。
// 摇杆只跟踪一个触点，中心在本次操作中保持不变。
var touchIndex: ?usize = null;
var center: math.Vector2 = .zero;
var offset: ?math.Vector2 = null; // 原始位移，null 表示没有摇杆操作。
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
    stickCamera = .windowDpi();
    const size = stickCamera.toWorld(window.rawSize);
    area = .init(.zero, .xy(size.x * 0.25, size.y));
}

// 更新功能按钮并返回摇杆原始位移，每帧与 update 二选一调用。
pub fn updateOffset() ?math.Vector2 {
    pad.update();
    if (window.resized) layout();
    offset = updateStick();
    return offset;
}

// 更新摇杆和功能按钮，将位移转换为四方向按键，下一帧生效。
// 每帧与 updateOffset 二选一调用，位移未超过 12 个界面单位时不触发方向键。
pub fn update() void {
    const value = updateOffset() orelse math.Vector2.zero;
    const deadZone = 12; // 摇杆中心不触发方向键的范围，使用界面单位。
    // 只取偏移较大的轴，一次仅产生一个方向。
    const horizontal = @abs(value.x) > @abs(value.y);
    const down: [4]bool = .{
        !horizontal and value.y < -deadZone,
        !horizontal and value.y > deadZone,
        horizontal and value.x < -deadZone,
        horizontal and value.x > deadZone,
    };
    const keys = [_]input.key.Code{ .UP, .DOWN, .LEFT, .RIGHT };
    for (keys, down, &held) |key, pressed, *previous| {
        if (pressed == previous.*) continue;
        input.key.queue(key, pressed);
        previous.* = pressed;
    }
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

// 场景切换前释放功能按键和摇杆产生的方向键，并结束摇杆操作。
pub fn reset() void {
    pad.reset();
    const keys = [_]input.key.Code{ .UP, .DOWN, .LEFT, .RIGHT };
    for (keys, held) |key, down| if (down) input.key.queue(key, false);

    held = @splat(false);
    touchIndex = null;
    offset = null;
}

// 切换到全窗口视口和摇杆使用的 DPI 相机。
pub fn begin() void {
    const size = window.rawSize;
    batch.useViewport(.init(.zero, size), size);
    camera.push(stickCamera);
}

// 恢复进入绘制前的相机和窗口视口。
pub fn end() void {
    camera.pop();
    batch.useViewport(window.viewRect, camera.size);
}

// 在窗口坐标下绘制图形和文字。
pub fn draw() void {
    begin();
    drawImage();
    drawText();
    end();
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
