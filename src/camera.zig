const std = @import("std");

const zhu = @import("zhu.zig");
const key = @import("window.zig").key;

const Vector2 = zhu.Vector2;

pub const Camera = struct {
    position: Vector2 = .zero,
    scale: Vector2 = .one,

    pub const window: Camera = .{};

    // 将平台界面尺寸转换为渲染像素，供触摸控件布局和绘制共用。
    pub fn windowDpi() Camera {
        return .{ .scale = .all(@import("window.zig").dpi()) };
    }

    // 在当前绘制视口内使用界面单位，抵消视口缩放并应用 DPI。
    pub fn viewDpi() Camera {
        const pixels = window.pixelScale();
        return .{ .scale = windowDpi().scale.div(pixels) };
    }

    pub fn windowAt(origin: Vector2) Camera {
        return .{ .position = origin.neg() };
    }

    pub fn windowScale(origin: Vector2, scale: Vector2) Camera {
        return .{ .position = origin.div(scale).neg(), .scale = scale };
    }

    // 此相机每个坐标单位对应的当前目标像素数。
    pub fn pixelScale(self: Camera) Vector2 {
        const scale = state.viewRect.size.div(state.size);
        return scale.mul(self.scale);
    }

    pub fn toWindow(self: Camera, point: Vector2) Vector2 {
        return point.sub(self.position).mul(self.scale);
    }

    pub fn toWorld(self: Camera, point: Vector2) Vector2 {
        return point.div(self.scale).add(self.position);
    }
};

// 当前绘制坐标状态，由 batch 在开始绘制、切换目标和视口时更新。
pub const State = struct {
    camera: Camera, // 本帧的基准相机，批次记录时保存快照。
    size: Vector2, // 当前绘制的逻辑尺寸。
    viewRect: zhu.Rect, // 当前绘制使用的实际像素视口。
};

pub var state: State = undefined;

// 当前绘制相机每个坐标单位对应的目标像素数。
pub fn queryPixelScale() Vector2 {
    const current = stack.getLastOrNull() orelse state.camera;
    return current.pixelScale();
}

var buffer: [8]Camera = undefined;
pub var stack: std.ArrayList(Camera) = .initBuffer(&buffer);
pub var main: Camera = .window;
// 仅在渲染时将相机平移对齐到实际像素。
// TODO：支持切换渲染相机时，重新考虑此设置的归属和实现。
pub var snap: bool = false;
pub var size: Vector2 = undefined; // 默认游戏逻辑尺寸，不随窗口像素尺寸变化。
pub var bound: Vector2 = undefined;

pub fn init(cameraSize: Vector2) void {
    main, size, bound = .{ .window, cameraSize, cameraSize };
    stack.clearRetainingCapacity();
}

pub fn push(camera: Camera) void {
    stack.appendAssumeCapacity(camera);
}

pub fn pop() void {
    _ = stack.pop();
}

pub fn toWindow(point: Vector2) Vector2 {
    return main.toWindow(point);
}

pub fn toWorld(point: Vector2) Vector2 {
    return main.toWorld(point);
}

// 返回主相机在世界坐标中的可见矩形，供地图裁剪使用。
pub fn mainWorldRect() zhu.Rect {
    return .init(main.position, size.div(main.scale));
}

pub fn control(distance: f32) void {
    if (key.held(.UP)) main.position.y -= distance;
    if (key.held(.DOWN)) main.position.y += distance;
    if (key.held(.LEFT)) main.position.x -= distance;
    if (key.held(.RIGHT)) main.position.x += distance;
}

pub fn clampBound() void {
    const max = bound.sub(size.div(main.scale)).max(.zero);
    main.position = main.position.clamp(.zero, max);
}

pub fn directFollow(pos: Vector2) void {
    main.position = pos.sub(size.div(main.scale).scale(0.5));
    clampBound();
}

// 目标使用世界坐标，死区大小使用画面逻辑单位，越界后立即跟随。
pub fn deadFollow(pos: Vector2, deadSize: Vector2) void {
    // 死区居中，画面上的宽高不受相机缩放影响。
    const min = size.sub(deadSize).scale(0.5);
    const max = min.add(deadSize);
    const point = main.toWindow(pos);

    // 将超出死区的距离换回世界单位，只移动越界的部分。
    const moved = point.sub(point.clamp(min, max)).div(main.scale);
    main.position = main.position.add(moved);
    clampBound();
}

pub fn smoothFollow(pos: Vector2, smooth: f32) void {
    const target = pos.sub(size.div(main.scale).scale(0.5));
    const distance = target.sub(main.position);

    const clampedSmooth = std.math.clamp(smooth, 0, 1);
    if (@abs(distance.x) < 1) main.position.x = target.x else {
        var moved = distance.x * clampedSmooth;
        if (@abs(moved) < 1) moved = zhu.ceilAway(moved);
        main.position.x += moved;
    }

    if (@abs(distance.y) < 1) main.position.y = target.y else {
        var moved = distance.y * clampedSmooth;
        if (@abs(moved) < 1) moved = zhu.ceilAway(moved);
        main.position.y += moved;
    }
    clampBound();
}
