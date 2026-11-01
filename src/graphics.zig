const std = @import("std");

const sk = @import("sokol");
const math = @import("math.zig");
const assets = @import("assets.zig");
const camera = @import("camera.zig");
const window = @import("window.zig");

pub const View = sk.gfx.View;

pub const queryBackend = sk.gfx.queryBackend;

pub const Vector2 = math.Vector2;
pub const ImageId = assets.Id;

// 图片实例的顶点布局，由资产模块暂存、合批模块提交绘制。
pub const Vertex = extern struct {
    position: math.Vector2 = .zero, // 世界坐标中的固定变换中心。
    layer: u8 = 0, // 纹理数组层号，与保留字节共用一个 UBYTE4 属性。
    reserved: [3]u8 = .{ 0, 0, 0 }, // 保留字节，暂不分配用途。
    radian: f32 = 0, // 旋转弧度
    size: math.Vector2, // 缩放后的绘制尺寸。
    pivot: math.Vector2 = .zero, // 固定中心在图片中的归一化位置。
    uvRect: math.Vector4, // 纹理 UV 区域
    color: Color = .white, // 乘色，按通道乘纹理。
    addColor: Color = .all(0), // 加色，乘色后按通道相加。
    skew: Vector2 = .zero, // 斜切弧度，x 改变 Y 轴，y 改变 X 轴方向。
};

comptime {
    // 编译时检查实例大小，防止字段变更破坏布局约定。
    std.debug.assert(@sizeOf(Vertex) == 64);
}

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
    pub const Frames = []const Frame;
    pub const Step = enum { next, loop, end };
    pub const Source = struct {
        imageId: ImageId,
        size: Vector2, // 单帧尺寸
        frames: Frames,
        loop: bool = true, // 是否循环播放
    };

    elapsed: f32 = -math.epsilon,
    index: u8 = 0,
    source: Source,
    image: Image,
    extend: u32 = 0,

    sourceIndex: u8 = 0,
    sources: []const Source = &.{},

    pub fn init(img: Image, size: Vector2, frames: Frames) Animation {
        return .{ .image = img.sub(.init(.zero, size)), .source = .{
            .imageId = 0,
            .size = size,
            .frames = frames,
        } };
    }

    pub fn initFinished(img: Image, size: Vector2, frames: Frames) Animation {
        var self = Animation.init(img, size, frames);
        self.stop();
        return self;
    }

    pub fn initSource(sources: []const Source) Animation {
        const source = sources[0];
        const image = assets.getImage(source.imageId).?;
        return .{
            .source = source,
            .image = image.sub(.init(.zero, source.size)),
            .sources = sources,
        };
    }

    pub fn subImage(self: *const Animation) Image {
        return self.subImageAt(@intCast(self.index));
    }

    pub fn frame(self: *const Animation) Frame {
        return self.source.frames[self.index];
    }

    pub fn subImageAt(self: *const Animation, index: usize) Image {
        const frames = self.source.frames;
        const offset = frames[@min(frames.len - 1, index)].offset;
        return self.image.sub(.init(offset, self.image.size));
    }

    pub fn play(self: *Animation, index: anytype) void {
        const sourceIndex = math.toIndex(u8, index);
        self.source = self.sources[sourceIndex];
        self.sourceIndex = sourceIndex;

        const image = assets.getImage(self.source.imageId).?;
        self.image = image.sub(.init(.zero, self.source.size));
        self.reset();
    }

    pub fn update(self: *Animation, delta: f32) ?Step {
        if (self.index == self.source.frames.len) return null; // 已经结束
        const firstUpdate = self.elapsed < 0;
        self.elapsed += delta;
        if (firstUpdate) return .next; //  第一次第一帧
        const current = self.source.frames[self.index];
        if (self.elapsed < current.duration) return null; // 还未到下一帧

        self.elapsed -= current.duration;
        self.index += 1;
        if (self.index < self.source.frames.len) return .next; // 下一帧
        if (!self.source.loop) return .end; // 动画结束
        self.index = 0; // 循环播放
        return .loop;
    }

    pub fn getEnumFrame(self: *const Animation, T: type) T {
        const extend = self.source.frames[self.index].extend;
        return @fromBackingInt(@intCast(extend));
    }

    pub fn getEnumExtend(self: *const Animation, T: type) T {
        return @fromBackingInt(@intCast(self.extend));
    }

    pub fn stop(self: *Animation) void {
        self.index = @intCast(self.source.frames.len);
    }

    pub fn isRunning(self: *const Animation) bool {
        return self.index < self.source.frames.len;
    }

    pub fn isFinished(self: *const Animation) bool {
        return self.index == self.source.frames.len;
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

// 图集取样使用纹理像素，绘制区域使用相对排版起点的逻辑单位。
pub const Glyph = struct { image: Image, rect: math.Rect, advance: f32 };

pub const Image = struct {
    view: sk.gfx.View = .{},
    layer: u8 = 0, // 纹理数组层号，范围 0～255。
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

pub const RenderTarget = struct {
    pass: sk.gfx.Pass = .{},
    image: Image = .{ .view = .{}, .size = .zero },

    // 释放两个视图及底层纹理，共享采样器仍由 assets 管理。
    pub fn deinit(self: RenderTarget) void {
        const texture = sk.gfx.queryViewImage(self.image.view);
        sk.gfx.destroyView(self.pass.attachments.colors[0]);
        assets.view.destroy(self.image.view);
        sk.gfx.destroyImage(texture);
    }
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
    assets.view.put(view, .{ .sampler = sampler });
    return .{
        .pass = pass,
        .image = .{ .view = view, .size = size },
    };
}

pub const RenderPass = struct {
    target: ?*const RenderTarget = null,
    viewport: ?math.Rect = null,

    // 返回实际像素视口；离屏默认覆盖纹理，窗口默认使用游戏视口。
    pub fn queryViewport(self: RenderPass) math.Rect {
        if (self.viewport) |view| return view;
        if (self.target) |target| return target.image.rect();
        return window.viewRect;
    }

    // 返回绘制坐标尺寸；窗口默认使用游戏逻辑尺寸，自定义区域使用像素尺寸。
    pub fn querySize(self: RenderPass) Vector2 {
        if (self.viewport) |view| return view.size;
        if (self.target) |target| return target.image.size;
        return camera.size;
    }
};

// 最近一次窗口目标 beginPass 的经过时间，离屏目标不计入。
// 包含交换链查询、开始渲染通道、清屏和设置视口，以及这些调用中的驱动等待。
// 不包含后续绘制、endPass 和 commit，也不是 GPU 的执行时间。
pub var beginPassTicks: u64 = 0;
pub fn beginPass(color: Color, renderPass: RenderPass) math.Rect {
    const start = sk.time.now();
    defer if (renderPass.target == null) {
        beginPassTicks = sk.time.since(start);
    };
    var action = sk.gfx.PassAction{};
    action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = @as(f32, @floatFromInt(color.r)) / 255,
            .g = @as(f32, @floatFromInt(color.g)) / 255,
            .b = @as(f32, @floatFromInt(color.b)) / 255,
            .a = @as(f32, @floatFromInt(color.a)) / 255,
        },
    };

    if (renderPass.target) |target| {
        var pass = target.pass;
        pass.action = action;
        sk.gfx.beginPass(pass);
    } else {
        const chain = sk.glue.swapchain();
        sk.gfx.beginPass(.{ .action = action, .swapchain = chain });
    }

    const view = renderPass.queryViewport();
    applyViewport(view.min, view.size);
    return view;
}

// 设置以渲染目标左上角为原点的像素视口。
pub fn applyViewport(position: Vector2, size: Vector2) void {
    sk.gfx.applyViewportf(position.x, position.y, size.x, size.y, true);
}

// 设置以渲染目标左上角为原点的像素裁剪区域。
pub fn applyScissor(position: Vector2, size: Vector2) void {
    sk.gfx.applyScissorRectf(position.x, position.y, size.x, size.y, true);
}

pub const endPass = sk.gfx.endPass;
pub const commit = sk.gfx.commit;

// RGBA 通道使用 0～255，计算时转为浮点，保存时舍入。
pub const Color = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const black = Color.gray(0, 255); // 黑色
    pub const white = Color.all(255); // 白色
    pub const midGray = Color.gray(128, 255); // 中灰色
    pub const red = Color.rgb(255, 0, 0); // 红色
    pub const green = Color.rgb(0, 255, 0); // 绿色
    pub const blue = Color.rgb(0, 0, 255); // 蓝色
    pub const yellow = Color.rgb(255, 255, 0); // 黄色
    pub const cyan = Color.rgb(0, 255, 255); // 青色
    pub const magenta = Color.rgb(255, 0, 255); // 品红色

    // 创建不透明颜色。
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    // 创建带透明度的颜色。
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    // 将 RGBA 四个通道设为同一个值。
    pub fn all(value: u8) Color {
        return .{ .r = value, .g = value, .b = value, .a = value };
    }

    // 创建带透明度的灰色。
    pub fn gray(v: u8, a: u8) Color {
        return .{ .r = v, .g = v, .b = v, .a = a };
    }

    // 将线性 RGB 转为 sRGB，保持透明度。
    pub fn toSrgb(self: Color) Color {
        return .{
            .r = linearToSrgb(self.r),
            .g = linearToSrgb(self.g),
            .b = linearToSrgb(self.b),
            .a = self.a,
        };
    }

    // 在两个颜色之间插值，结果限制在字节范围内。
    pub fn mix(self: Color, other: Color, t: f32) Color {
        var result: Color = undefined;
        inline for (.{ "r", "g", "b", "a" }) |field| {
            const start: f32 = @floatFromInt(@field(self, field));
            const end: f32 = @floatFromInt(@field(other, field));
            @field(result, field) = @intFromFloat(
                @round(std.math.clamp(std.math.lerp(start, end, t), 0, 255)),
            );
        }
        return result;
    }

    // 归一化后转换，再舍入到最近的字节值。
    fn linearToSrgb(value: u8) u8 {
        const v = @as(f32, @floatFromInt(value)) / 255;
        const result = if (v <= 0.0031308) v * 12.92 else //
            1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        return @intFromFloat(@round(std.math.clamp(result * 255, 0, 255)));
    }
};
