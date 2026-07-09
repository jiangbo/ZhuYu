const std = @import("std");

const math = @import("math.zig");
const key = @import("input.zig").key;

const Vector2 = math.Vector2;

pub const Camera = struct {
    position: Vector2,
    scale: Vector2 = .one,

    pub const window: Camera = .{ .position = .zero };

    pub fn windowAt(origin: Vector2) Camera {
        return .{ .position = origin.neg() };
    }

    pub fn windowScale(origin: Vector2, scale: Vector2) Camera {
        return .{ .position = origin.div(scale).neg(), .scale = scale };
    }

    pub fn toWindow(self: Camera, point: Vector2) Vector2 {
        return point.sub(self.position).mul(self.scale);
    }

    pub fn toWorld(self: Camera, point: Vector2) Vector2 {
        return point.div(self.scale).add(self.position);
    }
};

var buffer: [8]Camera = undefined;
pub var stack: std.ArrayList(Camera) = .initBuffer(&buffer);
pub var main: Camera = .window;
pub var size: Vector2 = undefined;
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

pub fn viewport() math.Rect {
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

pub fn roundPosition() void {
    const pixel = main.position.mul(main.scale).round();
    main.position = pixel.div(main.scale);
}

pub fn smoothFollow(pos: Vector2, smooth: f32) void {
    const target = pos.sub(size.div(main.scale).scale(0.5));
    const distance = target.sub(main.position);

    const clampedSmooth = std.math.clamp(smooth, 0, 1);
    if (@abs(distance.x) < 1) main.position.x = target.x else {
        var moved = distance.x * clampedSmooth;
        if (@abs(moved) < 1) moved = math.ceilAway(moved);
        main.position.x += moved;
    }

    if (@abs(distance.y) < 1) main.position.y = target.y else {
        var moved = distance.y * clampedSmooth;
        if (@abs(moved) < 1) moved = math.ceilAway(moved);
        main.position.y += moved;
    }
    clampBound();
}
