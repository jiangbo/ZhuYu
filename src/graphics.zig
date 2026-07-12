const std = @import("std");

const sk = @import("sokol");
const math = @import("math.zig");
const assets = @import("assets.zig");
const window = @import("window.zig");

pub const View = sk.gfx.View;

pub const queryBackend = sk.gfx.queryBackend;

pub const Vector2 = math.Vector2;
pub const ImageId = assets.Id;

pub fn queryViewSize(view: View) math.Vector {
    const image = sk.gfx.queryViewImage(view);
    return .{
        .x = @floatFromInt(sk.gfx.queryImageWidth(image)),
        .y = @floatFromInt(sk.gfx.queryImageHeight(image)),
    };
}

pub const Frame = struct {
    offset: Vector2, // 图集中的偏移位置
    duration: f32 = 0.1, // 持续时间，单位秒
    extend: u32 = 0, // 自由扩展
};

pub fn EnumAnimation(comptime T: type) type {
    return std.EnumArray(T, Animation);
}
pub const Animation = struct {
    pub const Clip = []const Frame;
    pub const Step = enum { next, loop, end };
    pub const Source = struct { imageId: ImageId, clip: Clip };

    elapsed: f32 = -math.epsilon,
    row: u8 = 0,
    index: u8 = 0,
    image: Image,
    clip: Clip,
    loop: bool = true,
    extend: u32 = 0,

    sourceIndex: u8 = 0,
    sources: []const Source = &.{},

    pub fn init(img: Image, size: Vector2, clip: Clip) Animation {
        return .{ .image = img.sub(.init(.zero, size)), .clip = clip };
    }

    pub fn initFinished(img: Image, size: Vector2, clip: Clip) Animation {
        const idx: u8 = @intCast(clip.len);
        const image = img.sub(.init(.zero, size));
        return .{ .image = image, .clip = clip, .index = idx };
    }

    pub fn initSource(src: []const Source, size: Vector2) Animation {
        const image = assets.getImage(src[0].imageId).?;
        var self = Animation.init(image, size, src[0].clip);
        self.sources = src;
        return self;
    }

    pub fn subImage(self: *const Animation) Image {
        return self.subImageAt(@intCast(self.index));
    }

    pub fn frame(self: *const Animation) Frame {
        return self.clip[self.index];
    }

    pub fn subImageAt(self: *const Animation, idx: usize) Image {
        const index = @min(self.clip.len - 1, idx);
        var offset = self.clip[index].offset;
        offset.y += self.image.size.y * @as(f32, @floatFromInt(self.row));
        return self.image.sub(.init(offset, self.image.size));
    }

    pub fn play(self: *Animation, index: anytype, loop: bool) void {
        self.playRow(index, self.row, loop);
    }

    pub fn playRow(self: *Animation, idx: anytype, row: anytype, loop: bool) void {
        const sourceIndex = math.toIndex(u8, idx);
        const next = self.sources[sourceIndex];
        const image = assets.getImage(next.imageId).?;
        self.image = image.sub(.init(.zero, self.image.size));
        self.clip, self.sourceIndex = .{ next.clip, sourceIndex };
        self.row, self.loop = .{ math.toIndex(u8, row), loop };
        self.reset();
    }

    pub fn update(self: *Animation, delta: f32) ?Step {
        if (self.index == self.clip.len) return null; // 已经结束
        const firstUpdate = self.elapsed < 0;
        self.elapsed += delta;
        if (firstUpdate) return .next; //  第一次第一帧
        const current = self.clip[self.index];
        if (self.elapsed < current.duration) return null; // 还未到下一帧

        self.elapsed -= current.duration;
        self.index += 1;
        if (self.index < self.clip.len) return .next; // 下一帧
        if (!self.loop) return .end; // 动画结束
        self.index = 0; // 循环播放
        return .loop;
    }

    pub fn getEnumFrame(self: *const Animation, T: type) T {
        return @enumFromInt(self.clip[self.index].extend);
    }

    pub fn getEnumExtend(self: *const Animation, T: type) T {
        return @enumFromInt(self.extend);
    }

    pub fn stop(self: *Animation) void {
        self.index = @intCast(self.clip.len);
    }

    pub fn isRunning(self: *const Animation) bool {
        return self.index < self.clip.len;
    }

    pub fn isFinished(self: *const Animation) bool {
        return self.index == self.clip.len;
    }

    pub fn reset(self: *Animation) void {
        self.index, self.elapsed = .{ 0, -math.epsilon };
    }
};

pub fn framesX(comptime count: u8, size: Vector2, d: f32) [count]Frame {
    var result: [count]Frame = undefined;
    for (&result, 0..) |*frame, i| {
        const index: f32 = @floatFromInt(i);
        frame.offset = .xy(index * size.x, 0);
        frame.duration = d;
    }
    return result;
}

pub fn loopFramesX(comptime count: u8, size: Vector2, d: f32) //
[count + count - 2]Frame {
    var result: [count + count - 2]Frame = undefined;
    for (&result, 0..) |*frame, i| {
        var index: f32 = @floatFromInt(i);
        if (i >= count) index = @floatFromInt(count + count - 2 - i);
        frame.offset = .xy(index * size.x, 0);
        frame.duration = d;
    }
    return result;
}

pub const Filter = enum { nearest, linear };

pub const Image = struct {
    view: sk.gfx.View = .{},
    sampler: sk.gfx.Sampler = .{},
    layer: f32 = 0,
    offset: math.Vector2 = .zero,
    size: math.Vector2 = .zero,

    pub const empty: Image = .{};

    pub fn sub(self: *const Image, subRect: math.Rect) Image {
        var image = self.*;
        image.offset = self.offset.add(subRect.min);
        image.size = subRect.size;
        return image;
    }

    pub fn rect(self: *const Image) math.Rect {
        return .init(self.offset, self.size);
    }

    pub fn uvFlip(self: Image, x: bool, y: bool) math.Vector4 {
        var uv = self.uvRect();
        if (x) uv.x, uv.z = .{ uv.x + uv.z, -uv.z };
        if (y) uv.y, uv.w = .{ uv.y + uv.w, -uv.w };
        return uv;
    }

    pub fn uvRect(self: Image) math.Vector4 {
        return .initSize(self.offset, self.size);
    }
};

pub const NineImage = struct {
    pub const Patch = struct { min: Vector2, max: Vector2 };
    pub const Source = struct { rect: math.Rect, patch: Patch };

    image: Image,
    patch: Patch,

    pub fn init(image: Image, patch: Patch) NineImage {
        return .{ .image = image, .patch = patch };
    }

    pub fn rectAt(self: NineImage, pos: Vector2) math.Rect {
        return .init(pos, self.image.size);
    }

    pub fn from(image: Image, source: Source) NineImage {
        return .init(image.sub(source.rect), source.patch);
    }
};

pub const Atlas = struct {
    imagePaths: []const [:0]const u8,
    size: math.Vector2,
    images: []const Image,
};

pub const Stats = struct {
    text: usize = 0,
};

pub var stats: Stats = .{};

pub const RenderTarget = struct {
    pass: sk.gfx.Pass = .{},
    image: Image = .{ .view = .{}, .size = .zero },
};

pub fn createRenderTarget(size: math.Vector2, filter: Filter) RenderTarget {
    const colorImage = sk.gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = @intFromFloat(size.x),
        .height = @intFromFloat(size.y),
        .sample_count = 1,
        .type = .ARRAY,
    });

    var pass = sk.gfx.Pass{};
    pass.attachments.colors[0] = sk.gfx.makeView(.{
        .color_attachment = .{ .image = colorImage },
    });

    const view = sk.gfx.makeView(.{
        .texture = .{ .image = colorImage },
    });
    const sampler = assets.sampler.get(filter);
    return .{
        .pass = pass,
        .image = .{ .view = view, .sampler = sampler, .size = size },
    };
}

pub const RenderPass = struct {
    target: ?*const RenderTarget = null,
    viewport: ?math.Rect = null,
};

pub fn beginPass(color: Color, renderPass: RenderPass) math.Rect {
    var action = sk.gfx.PassAction{};
    action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = @bitCast(color),
    };

    var viewport: ?math.Rect = renderPass.viewport;
    if (renderPass.target) |target| {
        var pass = target.pass;
        pass.action = action;
        sk.gfx.beginPass(pass);
        if (viewport == null) viewport = target.image.rect();
    } else {
        const chain = sk.glue.swapchain();
        sk.gfx.beginPass(.{ .action = action, .swapchain = chain });
        if (viewport == null) viewport = window.viewRect;
    }

    const view = viewport.?;
    sk.gfx.applyViewportf(view.min.x, view.min.y, //
        view.size.x, view.size.y, true);
    return view;
}

pub const endPass = sk.gfx.endPass;
pub const commit = sk.gfx.commit;

pub const Color = extern struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub const black = Color.rgb(0, 0, 0); // 黑色
    pub const white = Color.rgb(1, 1, 1); // 白色
    pub const midGray = Color.rgb(0.5, 0.5, 0.5); // 中灰色

    pub const red = Color.rgb(1, 0, 0); // 红色
    pub const green = Color.rgb(0, 1, 0); // 绿色
    pub const blue = Color.rgb(0, 0, 1); // 蓝色

    pub const yellow = Color.rgb(1, 1, 0); // 黄色
    pub const cyan = Color.rgb(0, 1, 1); // 青色
    pub const magenta = Color.rgb(1, 0, 1); // 品红色
    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn gray(v: f32, a: f32) Color {
        return .{ .r = v, .g = v, .b = v, .a = a };
    }

    pub fn toSrgb(self: Color) Color {
        return .{
            .r = linearToSrgb(self.r),
            .g = linearToSrgb(self.g),
            .b = linearToSrgb(self.b),
            .a = self.a,
        };
    }

    pub fn mix(self: Color, other: Color, t: f32) Color {
        return .{
            .r = std.math.lerp(self.r, other.r, t),
            .g = std.math.lerp(self.g, other.g, t),
            .b = std.math.lerp(self.b, other.b, t),
            .a = std.math.lerp(self.a, other.a, t),
        };
    }

    fn linearToSrgb(v: f32) f32 {
        if (v <= 0.0031308) return v * 12.92;
        return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
    }
};
