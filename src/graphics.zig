const std = @import("std");
const sk = @import("sokol");

const zhu = @import("zhu.zig");
const assets = @import("assets.zig");
const camera = @import("camera.zig");
const window = @import("window.zig");

pub const View = sk.gfx.View;

pub const queryBackend = sk.gfx.queryBackend;

// 使用引擎顶点布局创建流水线，资源由 assets.gpu 统一释放。
pub fn createPipeline(shaderDesc: sk.gfx.ShaderDesc) sk.gfx.Pipeline {
    var vertexLayout = sk.gfx.VertexLayoutState{};

    vertexLayout.attrs[0].format = .FLOAT2;
    vertexLayout.attrs[1].format = .UBYTE4;
    vertexLayout.attrs[2].format = .FLOAT;
    vertexLayout.attrs[3].format = .FLOAT2;
    vertexLayout.attrs[4].format = .FLOAT2;
    vertexLayout.attrs[5].format = .FLOAT4;
    vertexLayout.attrs[6].format = .UBYTE4N;
    vertexLayout.attrs[7].format = .UBYTE4N;
    vertexLayout.attrs[8].format = .FLOAT2;
    vertexLayout.buffers[0].step_func = .PER_INSTANCE;

    const shaderHandle = sk.gfx.makeShader(shaderDesc);
    assets.gpu.addShader(shaderHandle);

    const pipeline = sk.gfx.makePipeline(.{
        .shader = shaderHandle,
        .layout = vertexLayout,
        .primitive_type = .TRIANGLE_STRIP,
        .colors = init: {
            var c: [8]sk.gfx.ColorTargetState = @splat(.{});
            c[0] = .{ .blend = .{
                .enabled = true,
                .src_factor_rgb = .ONE,
                .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                .src_factor_alpha = .ONE,
                .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            } };
            break :init c;
        },
    });
    assets.gpu.addPipeline(pipeline);
    return pipeline;
}

const Vector2 = zhu.Vector2;
pub const ImageId = assets.Id;

pub const DrawOption = struct {
    size: ?Vector2 = null, // 大小
    scale: Vector2 = .one, // 围绕 pivot 缩放。
    anchor: Vector2 = .zero, // 变换前的定位锚点，归一化坐标。
    pivot: Vector2 = .center, // 缩放、斜切和旋转共用的固定中心。
    radian: f32 = 0, // 旋转弧度
    skew: Vector2 = .zero, // 斜切弧度，x 改变 Y 轴，y 改变 X 轴方向。
    uvRect: ?zhu.Vector4 = null, // 纹理 UV 区域
    color: Color = .white, // 乘色；Alpha 控制图片本身的不透明度。
    // 额外增加颜色，让画面变亮；Alpha 控制强度，零表示不加色。
    // 加色不受 color.a 控制，也不增加对背景的遮挡。
    // 普通半透明：addColor 保持零，调整 color.a。
    // 纯加法发光：color.a 设为零，用 addColor 设置颜色和强度。
    // 图片和加色一起淡出时，需要同时降低 color.a 和 addColor.a。
    addColor: Color = .all(0),
    filter: ?Filter = null, // null 使用图片自身的采样方式。
    snap: ?bool = null, // null 使用 batch 的默认设置。
};

// 图片实例的顶点布局，由资产模块暂存、合批模块提交绘制。
pub const Vertex = extern struct {
    position: zhu.Vector2 = .zero, // 世界坐标中的固定变换中心。
    layer: u8 = 0, // 纹理数组层号，与保留字节共用一个 UBYTE4 属性。
    filter: Filter = .nearest, // 本实例的采样方式。
    snap: bool = false, // 是否对齐顶点到像素边界。
    reservedAfter: u8 = 0, // 保留字节，暂不分配用途。
    radian: f32 = 0, // 旋转弧度
    size: zhu.Vector2, // 缩放后的绘制尺寸。
    pivot: zhu.Vector2 = .zero, // 固定中心在图片中的归一化位置。
    uvRect: zhu.Vector4, // 纹理 UV 区域
    color: Color = .white, // 乘色，按通道乘纹理。
    // 加色规则见 DrawOption；自己的 Alpha 控制强度，不受 color.a 控制。
    addColor: Color = .all(0),
    skew: Vector2 = .zero, // 斜切弧度，x 改变 Y 轴，y 改变 X 轴方向。
};

comptime {
    // 编译时检查实例大小，防止字段变更破坏布局约定。
    std.debug.assert(@sizeOf(Vertex) == 64);
}

pub fn queryViewSize(view: View) zhu.Vector {
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

/// 配置使用整数或枚举扩展值，转换时该值必须能用 u16 表示。
/// frames 始终借用原切片，调用方负责保持其有效。
pub fn SourceT(comptime T: type) type {
    return struct {
        imageId: ImageId,
        size: Vector2, // 单帧尺寸
        frames: []const Frame,
        loop: bool = true, // 是否循环播放
        // 整数默认 0，枚举默认第一个声明的值。
        extend: T = switch (@typeInfo(T)) {
            .int => 0,
            .@"enum" => std.enums.values(T)[0],
            else => @compileError("extend must be an integer or enum"),
        },

        pub fn toSource(self: @This()) Animation.Source {
            return .{
                .imageId = self.imageId,
                .size = self.size,
                .frames = self.frames,
                .loop = self.loop,
                .extend = zhu.toIndex(u16, self.extend),
            };
        }
    };
}

pub fn SliceSource(T: type) type {
    return []const SourceT(T);
}

/// 按枚举名称配置动画源，可直接从 ZON 导入，省略的动作默认为 null。
pub fn EnumSource(T: type) type {
    const Source = ?Animation.Source;
    return std.enums.EnumFieldStruct(T, Source, @as(Source, null));
}

pub fn Sources(T: type) type {
    return struct {
        sources: SliceSource(T),

        pub fn init(sources: SliceSource(T)) @This() {
            return .{ .sources = sources };
        }

        pub fn initChecked(sources: SliceSource(T)) @This() {
            for (sources, 0..) |src, index| {
                std.debug.assert(@backingInt(src.extend) == index);
            }
            return .init(sources);
        }

        /// 编译期整理缺项或乱序配置；枚举必须从零开始连续编号。
        /// 缺省动作的 frames 为空，不能用于播放。
        pub fn generate(comptime configs: SliceSource(T)) @This() {
            const sources = comptime blk: {
                const values = std.enums.values(T);
                var result = std.mem.zeroes([values.len]SourceT(T));
                for (values, 0..) |tag, index| {
                    std.debug.assert(@backingInt(tag) == index);
                    result[index].extend = tag;
                }
                for (configs) |src| {
                    result[@backingInt(src.extend)] = src;
                }
                break :blk result;
            };
            return .{ .sources = &sources };
        }

        /// 编译期按字段名生成源，缺省动作保留空帧占位。
        pub fn fromStruct(comptime configs: EnumSource(T)) @This() {
            const sources = comptime blk: {
                const values = std.enums.values(T);
                var result: [values.len]SourceT(T) = undefined;
                for (values, 0..) |tag, index| {
                    std.debug.assert(@backingInt(tag) == index);
                    const src = @field(configs, @tagName(tag)) orelse
                        std.mem.zeroes(Animation.Source);
                    result[index] = .{
                        .imageId = src.imageId,
                        .size = src.size,
                        .frames = src.frames,
                        .loop = src.loop,
                        .extend = tag,
                    };
                }
                break :blk result;
            };
            return .{ .sources = &sources };
        }

        pub fn get(self: @This(), action: T) Animation.Source {
            return self.sources[zhu.toIndex(usize, action)].toSource();
        }
    };
}

pub fn EnumAnimation(comptime T: type) type {
    return std.EnumArray(T, Animation);
}
pub const Animation = struct {
    comptime {
        std.debug.assert(@sizeOf(@This()) <= 64);
    }

    pub const Frames = []const Frame;
    pub const Step = enum { start, next, loop, end };
    pub const Source = SourceT(u16);

    // 负号表示首帧事件尚未取出；其绝对值仍是累计时间。
    elapsed: f32 = -0.0,
    index: u16 = 0,
    row: u16 = 0,
    source: Source,
    image: Image,

    pub fn init(image: Image, size: Vector2, frames: Frames) Animation {
        std.debug.assert(frames.len != 0);
        for (frames) |f| std.debug.assert(f.duration > 0);
        const id = std.math.maxInt(u32);
        return .{
            .source = .{ .imageId = id, .frames = frames, .size = size },
            .image = image,
        };
    }

    pub fn initSource(source: Source) Animation {
        std.debug.assert(source.frames.len != 0);
        for (source.frames) |f| std.debug.assert(f.duration > 0);
        const image = assets.getImage(source.imageId).?;
        return .{ .source = source, .image = image };
    }

    pub fn initFinished(source: Source) Animation {
        var self = Animation.initSource(source);
        self.stop();
        return self;
    }

    pub fn subImage(self: *const Animation) Image {
        return self.subImageAt(@intCast(self.index));
    }

    pub fn frame(self: *const Animation) Frame {
        const frames = self.source.frames;
        return frames[@min(frames.len - 1, self.index)];
    }

    pub fn subImageAt(self: *const Animation, index: usize) Image {
        const frames = self.source.frames;
        var offset = frames[@min(frames.len - 1, index)].offset;
        offset.y += @as(f32, @floatFromInt(self.row)) * self.source.size.y;
        return self.image.sub(.init(offset, self.source.size));
    }

    pub fn play(self: *Animation, source: Source, row: anytype) void {
        self.* = .initSource(source);
        self.row = zhu.toIndex(u16, row);
    }

    pub fn playSource(self: *Animation, source: Source) void {
        self.play(source, self.row);
    }

    pub fn playRow(self: *Animation, row: anytype) void {
        self.row = zhu.toIndex(u16, row);
        self.reset();
    }

    /// 推进到当前时间对应的帧，丢弃途中事件。
    pub fn update(self: *Animation, delta: f32) void {
        self.advance(delta);
        while (self.nextStep() != null) {}
    }

    /// 累加时间；随后调用 nextStep 逐个取出事件。
    pub fn advance(self: *Animation, delta: f32) void {
        std.debug.assert(delta >= 0);
        if (self.isFinished()) return;
        const starting = std.math.signbit(self.elapsed);
        self.elapsed += if (starting) -delta else delta;
    }

    /// 取出下一个事件；play/reset 会清除剩余时间并重新产生首帧事件。
    pub fn nextStep(self: *Animation) ?Step {
        if (self.isFinished()) return null;
        if (std.math.signbit(self.elapsed)) {
            self.elapsed = -self.elapsed;
            return .start;
        }
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
        return @fromBackingInt(@intCast(self.frame().extend));
    }

    pub fn getEnumExtend(self: *const Animation, T: type) T {
        return @fromBackingInt(@intCast(self.source.extend));
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
        self.index, self.elapsed = .{ 0, -0.0 };
    }
};

pub const frame = struct {
    pub fn x(comptime count: u8, size: Vector2, d: f32) [count]Frame {
        var result: [count]Frame = undefined;
        for (&result, 0..) |*item, i| {
            const index: f32 = @floatFromInt(i);
            item.* = .{ .offset = .xy(index * size.x, 0), .duration = d };
        }
        return result;
    }

    /// 倒序复制完整帧；输入非空，输出容量至少为输入长度，不能重叠。
    pub fn reverse(frames: []const Frame, buffer: []Frame) []Frame {
        std.debug.assert(frames.len > 0 and buffer.len >= frames.len);
        const result = buffer[0..frames.len];
        @memcpy(result, frames);
        std.mem.reverse(Frame, result);
        return result;
    }

    /// 生成不重复端点的往返序列；输入非空，输出容量需足够，不能重叠。
    pub fn pingPong(frames: []const Frame, buffer: []Frame) []Frame {
        const len = pingPongLen(frames.len);
        std.debug.assert(buffer.len >= len);
        const result = buffer[0..len];
        @memcpy(result[0..frames.len], frames);
        if (frames.len > 2) {
            _ = reverse(frames[1 .. frames.len - 1], result[frames.len..]);
        }
        return result;
    }

    fn pingPongLen(len: usize) usize {
        std.debug.assert(len > 0);
        return if (len == 1) 1 else len * 2 - 2;
    }

    pub fn pingPongX(comptime n: u8, size: Vector2, d: f32) [pingPongLen(n)]Frame {
        const frames = x(n, size, d);
        var result: [pingPongLen(n)]Frame = undefined;
        _ = pingPong(&frames, &result);
        return result;
    }
};

pub const Filter = enum(u8) { nearest, linear };

// 图集取样使用纹理像素，绘制区域使用相对排版起点的逻辑单位。
pub const Glyph = struct { image: Image, rect: zhu.Rect, advance: f32 };

pub const Image = struct {
    view: sk.gfx.View = .{},
    layer: u8 = 0, // 纹理数组层号，范围 0～255。
    filter: Filter = .nearest, // 图片默认的采样方式。
    offset: zhu.Vector2 = .zero,
    size: zhu.Vector2 = .zero,

    pub const empty: Image = .{};

    /// 是否持有图片视图。
    pub fn isValid(self: *const Image) bool {
        return self.view.id != 0;
    }

    pub fn sub(self: *const Image, subRect: zhu.Rect) Image {
        var image = self.*;
        image.offset = self.offset.add(subRect.min);
        image.size = subRect.size;
        return image;
    }

    pub fn rect(self: *const Image) zhu.Rect {
        return .init(self.offset, self.size);
    }

    pub fn uvFlip(self: Image, x: bool, y: bool) zhu.Vector4 {
        var uv = self.uvRect();
        if (x) uv.x, uv.z = .{ uv.x + uv.z, -uv.z };
        if (y) uv.y, uv.w = .{ uv.y + uv.w, -uv.w };
        return uv;
    }

    pub fn uvRect(self: Image) zhu.Vector4 {
        return .initSize(self.offset, self.size);
    }
};

pub const NineImage = struct {
    pub const Patch = struct { min: Vector2, max: Vector2 };
    pub const Source = struct { rect: zhu.Rect, patch: Patch };

    image: Image,
    patch: Patch,

    pub fn init(image: Image, patch: Patch) NineImage {
        return .{ .image = image, .patch = patch };
    }

    pub fn rectAt(self: NineImage, pos: Vector2) zhu.Rect {
        return .init(pos, self.image.size);
    }

    pub fn from(image: Image, source: Source) NineImage {
        return .init(image.sub(source.rect), source.patch);
    }
};

pub const Atlas = struct {
    imagePaths: []const [:0]const u8,
    size: zhu.Vector2,
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

pub fn createRenderTarget(size: zhu.Vector2, filter: Filter) RenderTarget {
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
    assets.view.put(view, .{ .sampler = assets.sampler.get(filter) });
    return .{
        .pass = pass,
        .image = .{ .view = view, .size = size, .filter = filter },
    };
}

pub const RenderPass = struct {
    target: ?*const RenderTarget = null,
    viewport: ?zhu.Rect = null,

    // 返回实际像素视口；离屏默认覆盖纹理，窗口默认使用游戏视口。
    pub fn queryViewport(self: RenderPass) zhu.Rect {
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
pub fn beginPass(color: Color, renderPass: RenderPass) zhu.Rect {
    const start = sk.time.now();
    defer if (renderPass.target == null) {
        beginPassTicks = sk.time.since(start);
    };
    var action = sk.gfx.PassAction{};
    action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = color.toFloat(),
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

    // 返回指定透明度的颜色，比例限制在 0～1，RGB 保持不变。
    pub fn withAlpha(self: Color, percent: f32) Color {
        const opacity = std.math.clamp(percent, 0, 1);
        var color = self;
        color.a = @intFromFloat(@round(opacity * 255));
        return color;
    }

    // 按比例调整现有透明度，RGB 保持不变。
    pub fn scaleAlpha(self: Color, scale: f32) Color {
        var color = self;
        const alpha: f32 = @floatFromInt(self.a);
        color.a = @intFromFloat(@round(alpha * std.math.clamp(scale, 0, 1)));
        return color;
    }

    // 将 RGBA 通道归一化为 0～1，复用 Sokol 的浮点颜色类型。
    pub fn toFloat(self: Color) sk.gfx.Color {
        return .{
            .r = @as(f32, @floatFromInt(self.r)) / 255,
            .g = @as(f32, @floatFromInt(self.g)) / 255,
            .b = @as(f32, @floatFromInt(self.b)) / 255,
            .a = @as(f32, @floatFromInt(self.a)) / 255,
        };
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
