const std = @import("std");

pub const sokol = @import("sokol");
pub const window = @import("window.zig");
pub const assets = @import("assets.zig");
pub const audio = @import("audio.zig");
pub const graphics = @import("graphics.zig");
pub const debug = @import("debug.zig");
pub const batch = @import("batch.zig");
pub const camera = @import("camera.zig");
pub const math = @import("math.zig");
pub const input = @import("input.zig");
pub const widget = @import("widget.zig");
pub const text = @import("text.zig");
pub const enums = math.enums;
pub const random = math.random;
pub const key = input.key;
pub const mouse = input.mouse;

pub const extend = struct {
    pub const tiled = @import("extend/tiled.zig");
};

pub const Timer = math.Timer;
pub const Image = graphics.Image;
pub const NineImage = graphics.NineImage;
pub const Atlas = graphics.Atlas;
pub const Vector2 = math.Vector2;
pub const Rect = math.Rect;
pub const Color = graphics.Color;
pub const Animation = graphics.Animation;
pub const EnumAnimation = graphics.EnumAnimation;
pub const Allocator = assets.memory.OomAllocator;

comptime {
    _ = @import("internal/c.zig");
}

pub const clamp = std.math.clamp;
pub const format = text.format;
pub const formatZ = text.formatZ;
pub const getImage = assets.getImageByPath;
pub const oom = assets.memory.oom;

pub const testing = struct {
    pub const allocator: Allocator = .{ .raw = std.testing.allocator };
};
