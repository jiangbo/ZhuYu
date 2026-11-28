const std = @import("std");
const sk = @import("sokol");
const shader = @import("shader");
const options = @import("options");

const math = @import("internal/math.zig");
const graphics = @import("graphics.zig");
const assets = @import("assets.zig");
const camera = @import("camera.zig");

const Image = graphics.Image;
const ImageId = graphics.ImageId;
const Color = graphics.Color;
const RenderPass = graphics.RenderPass;
const Vector2 = math.Vector2;
const Vertex = graphics.Vertex;

pub const Option = struct {
    size: ?Vector2 = null, // 大小
    scale: Vector2 = .one, // 围绕 pivot 缩放。
    anchor: Vector2 = .zero, // 变换前的定位锚点，归一化坐标。
    pivot: Vector2 = .center, // 缩放、斜切和旋转共用的固定中心。
    radian: f32 = 0, // 旋转弧度
    skew: Vector2 = .zero, // 斜切弧度，x 改变 Y 轴，y 改变 X 轴方向。
    uvRect: ?math.Vector4 = null, // 纹理 UV 区域
    color: Color = .white, // 乘色；Alpha 控制图片本身的不透明度。
    // 额外增加颜色，让画面变亮；Alpha 控制强度，零表示不加色。
    // 加色不受 color.a 控制，也不增加对背景的遮挡。
    // 普通半透明：addColor 保持零，调整 color.a。
    // 纯加法发光：color.a 设为零，用 addColor 设置颜色和强度。
    // 图片和加色一起淡出时，需要同时降低 color.a 和 addColor.a。
    addColor: Color = .all(0),
    snap: ?bool = null, // null 使用 batch 的默认设置。
};

pub const Command = union(enum) {
    target: TargetCommand, // 渲染目标
    viewport: math.Rect, // 目标像素区域。
    scissor: math.Rect, // 目标像素裁剪，离屏翻转在提交时处理。
    draw: DrawCommand, // 绘制命令
    custom: CustomCommand, // 自定义绘制回调
};

pub const CustomFn = *const fn (?*anyopaque) void;
pub const CustomCommand = struct { ctx: ?*anyopaque, func: CustomFn };
pub const TargetCommand = struct { color: Color, pass: RenderPass };
pub const DrawCommand = struct {
    start: u32 = 0, // 起始顶点索引
    end: ?u32 = null, // 结束顶点索引，null 表示未结束。
    view: graphics.View = .{}, // 纹理视图
    pipeline: graphics.Pipeline, // 本批次使用的流水线。
    camera: camera.Camera, // 本批次的实际渲染相机快照。
    filter: graphics.Filter, // 单采样器模式下使用的采样方式。
    size: Vector2, // 本批次绘制的逻辑尺寸。
};

pub var whiteImage: graphics.Image = undefined;
pub var circleImage: graphics.Image = undefined;
// 图片绘制是否默认对齐顶点到目标像素。
pub var snap: bool = false;

// 命令借用调用方提供的固定缓冲区。
pub var commands: std.ArrayList(Command) = .empty;
// 初始化以来，完整帧的命令数峰值。
pub var commandPeak: usize = 0;

// 满时提供更大的列表，保留原有命令及顺序。缓冲区仍由调用方管理。
pub var onFull: ?*const fn ([]Command) std.ArrayList(Command) = null;
var currentPipeline: ?graphics.Pipeline = null;

var vertexBuffer: sk.gfx.Buffer = .{}; // 上传后用于绘制的顶点缓冲。
var defaultPipeline: sk.gfx.Pipeline = undefined; // 默认图片流水线。
var flushed = false;

// 命令缓冲区由调用方持有，使用期间必须保持有效。
// image 用于圆形等基础图形；不绘制基础图形时可传 null。
pub fn init(cmds: []Command, image: ?Image) void {
    commands = .initBuffer(cmds);
    commandPeak = 0;
    defaultPipeline = graphics.createQuadPipeline(.alpha);

    // 调用方提供圆形图片，其中心区域必须为白色。
    // 建议与其他素材放在同一图集，避免绘制基础图形时切换纹理、打断合批。
    circleImage = image orelse return;
    const rect = math.Rect.init(.zero, circleImage.size);
    whiteImage = circleImage.sub(rect.centerScale(0.25));
}

// 开始记录本帧绘制和首个目标，GPU pass 在 flush 时开启。
pub fn beginDraw(color: Color, pass: RenderPass) void {
    assets.beginDraw();
    commands.clearRetainingCapacity();
    flushed = false;
    camera.state.camera, camera.state.snap = .{ camera.main, camera.snap };
    useTarget(color, pass);
}

pub fn useTarget(color: Color, pass: graphics.RenderPass) void {
    endDrawCommand();
    currentPipeline = null;
    appendCommand(.{ .target = .{ .color = color, .pass = pass } });
    camera.state.viewRect = pass.queryViewport();
    camera.state.size = pass.querySize();
}

// 切换后续批次使用的流水线；null 恢复纹理或默认流水线。
pub fn usePipeline(pipeline: ?graphics.Pipeline) void {
    if (std.meta.eql(currentPipeline, pipeline)) return;
    endDrawCommand();
    currentPipeline = pipeline;
}

// 相机栈为空时，切换后续批次的基准相机和投影取整设置。
pub fn useCamera(view: camera.Camera, cameraSnap: bool) void {
    std.debug.assert(camera.stack.items.len == 0);
    endDrawCommand();
    camera.state.camera, camera.state.snap = .{ view, cameraSnap };
}

// 设置目标像素区域和对应的逻辑尺寸，同时重置裁剪区域。
pub fn useViewport(rect: math.Rect, size: Vector2) void {
    endDrawCommand();
    camera.state.viewRect = rect;
    camera.state.size = size;
    appendCommand(.{ .viewport = rect });
}

// 裁剪使用当前视口的逻辑坐标，不受相机影响；null 恢复完整视口。
pub fn useScissor(rect: ?math.Rect) void {
    endDrawCommand();
    var clip = camera.state.viewRect;
    if (rect) |area| {
        const scale = clip.size.div(camera.state.size);
        clip.min = clip.min.add(area.min.mul(scale));
        clip.size = area.size.mul(scale);
    }
    appendCommand(.{ .scissor = clip });
}

// 在命令队列当前位置插入自定义 GPU 操作，ctx 必须保持有效直到 endDraw() 完成。
pub fn addCustomCommand(ctx: ?*anyopaque, func: CustomFn) void {
    endDrawCommand();
    appendCommand(.{ .custom = .{ .ctx = ctx, .func = func } });
}

// 存在未结束的绘制命令时结束它，下一次绘制会创建新命令。
pub fn endDrawCommand() void {
    if (currentDraw()) |draw| draw.end = @intCast(assets.frameStats.vertex);
}

fn currentDraw() ?*DrawCommand {
    std.debug.assert(!flushed);
    if (commands.items.len == 0) return null;
    switch (commands.items[commands.items.len - 1]) {
        .draw => |*draw| return if (draw.end == null) draw else null,
        else => return null,
    }
}

fn appendCommand(cmd: Command) void {
    commands.appendBounded(cmd) catch {
        const len = commands.items.len;
        const grow = onFull orelse
            std.debug.panic("commands full (capacity {d})", .{len});
        commands = grow(commands.items);
        if (commands.items.len != len or commands.capacity <= len) {
            const msg = "onFull must keep {d} commands and increase capacity";
            std.debug.panic(msg, .{len});
        }
        commands.appendAssumeCapacity(cmd);
    };
}

fn addCommand(image: Image) *DrawCommand {
    endDrawCommand();
    var view = camera.state.camera;
    const area = camera.state.viewRect.size;
    const pixels: Vector2 = .xy(@trunc(area.x), @trunc(area.y));
    if (camera.state.snap and pixels.x > 0 and pixels.y > 0) {
        // 坐标转换与 GPU 投影共用同一份按实际视口像素对齐的相机。
        const scale = view.scale.mul(pixels.div(camera.state.size));
        view.position = view.position.mul(scale).round().div(scale);
    }
    const pip = currentPipeline orelse
        assets.gpu.getViewPipeline(image.view) orelse defaultPipeline;
    appendCommand(.{ .draw = .{
        .start = @intCast(assets.frameStats.vertex),
        .view = image.view,
        .pipeline = pip,
        .camera = view,
        .filter = image.filter,
        .size = camera.state.size,
    } });
    return currentDraw().?;
}

fn ensureDraw(image: Image) *DrawCommand {
    const cmd = currentDraw() orelse return addCommand(image);
    const same = cmd.view.id == image.view.id and
        (options.samplers or cmd.filter == image.filter);
    return if (same) cmd else addCommand(image);
}

// 直接提交调用方准备好的顶点，不修改其绘制设置。
pub fn drawVertices(image: Image, items: []const Vertex) void {
    _ = ensureDraw(image);
    assets.gpu.addVertices(items);
}

pub fn drawDebug(rect: math.Rect) void {
    drawRect(rect, .{ .color = .rgba(255, 0, 255, 102) });
}

pub const LineOption = struct { color: Color = .white, width: f32 = 1 };

/// 绘制轴对齐的线
pub fn drawAxisLine(start: Vector2, end: Vector2, option: LineOption) void {
    const rectOption = RectOption{ .color = option.color };
    const halfWidth = -@floor(option.width / 2);
    if (start.x == end.x) {
        const size = Vector2.xy(option.width, end.y - start.y);
        drawRect(.init(start.addX(halfWidth), size), rectOption);
    } else if (start.y == end.y) {
        const size = Vector2.xy(end.x - start.x, option.width);
        drawRect(.init(start.addY(halfWidth), size), rectOption);
    }
}

/// 绘制任意线
pub fn drawLine(start: Vector2, end: Vector2, option: LineOption) void {
    const vector = end.sub(start);
    const y = start.y - option.width / 2;
    drawImage(whiteImage, .xy(start.x, y), .{
        .size = .xy(vector.length(), option.width),
        .color = option.color,
        .radian = vector.atan2(),
        .pivot = .xy(0, 0.5),
    });
}

pub fn drawRectBorder(rect: math.Rect, width: f32, c: Color) void {
    const color = RectOption{ .color = c };
    drawRect(.init(rect.min, .xy(rect.size.x, width)), color); // 上
    var start = rect.min.addY(rect.size.y - width);
    drawRect(.init(start, .xy(rect.size.x, width)), color); // 下
    const size: Vector2 = .xy(width, rect.size.y - 2 * width);
    drawRect(.init(rect.min.addY(width), size), color); // 左
    start = rect.min.addXY(rect.size.x - width, width);
    drawRect(.init(start, size), color); // 右
}

pub const RectOption = struct { color: Color = .white, radian: f32 = 0 };
pub fn drawRect(rect: math.Rect, option: RectOption) void {
    drawImage(whiteImage, rect.min, .{
        .size = rect.size,
        .color = option.color,
        .radian = option.radian,
    });
}

pub fn drawCircle(position: Vector2, option: Option) void {
    drawImage(circleImage, position, option);
}

pub fn drawAxisCapsule(rect: math.Rect, color: Color) void {
    if (rect.size.x <= 0 or rect.size.y <= 0) return;

    if (rect.size.x >= rect.size.y) {
        const radius = rect.size.y * 0.5;
        const half = circleImage.size.mul(.xy(0.5, 1));
        const size = Vector2.xy(radius, rect.size.y);

        var image = circleImage.sub(.init(.zero, half));
        drawImage(image, rect.min, .{ .size = size, .color = color });

        const middleRect = math.Rect.init(
            rect.min.addX(radius),
            .xy(rect.size.x - rect.size.y, rect.size.y),
        );
        if (middleRect.size.x > 0 and middleRect.size.y > 0) {
            drawRect(middleRect, .{ .color = color });
        }

        image = circleImage.sub(.init(.xy(half.x, 0), half));
        const pos = rect.min.addX(middleRect.size.x + radius);
        drawImage(image, pos, .{ .size = size, .color = color });
        return;
    }

    const radius = rect.size.x * 0.5;
    const half = circleImage.size.mul(.xy(1, 0.5));
    const size = Vector2.xy(rect.size.x, radius);

    var image = circleImage.sub(.init(.zero, half));
    drawImage(image, rect.min, .{ .size = size, .color = color });

    const middleRect = math.Rect.init(
        rect.min.addY(radius),
        .xy(rect.size.x, rect.size.y - rect.size.x),
    );
    if (middleRect.size.x > 0 and middleRect.size.y > 0) {
        drawRect(middleRect, .{ .color = color });
    }

    image = circleImage.sub(.init(.xy(0, half.y), half));
    const pos = rect.min.addY(middleRect.size.y + radius);
    drawImage(image, pos, .{ .size = size, .color = color });
}

pub fn drawNine(nine: graphics.NineImage, rect: math.Rect) void {
    const left = nine.patch.min.x;
    const top = nine.patch.min.y;
    const right = nine.patch.max.x;
    const bottom = nine.patch.max.y;

    std.debug.assert(rect.size.x >= left + right);
    std.debug.assert(rect.size.y >= top + bottom);

    const centerW = rect.size.x - left - right;
    const centerH = rect.size.y - top - bottom;

    const srcX = [_]f32{ 0, left, nine.image.size.x - right };
    const srcY = [_]f32{ 0, top, nine.image.size.y - bottom };
    const srcW = [_]f32{ left, nine.image.size.x - left - right, right };
    const srcH = [_]f32{ top, nine.image.size.y - top - bottom, bottom };

    const min = rect.min;
    const dstX = [_]f32{ min.x, min.x + left, min.x + left + centerW };
    const dstY = [_]f32{ min.y, min.y + top, min.y + top + centerH };
    const dstW = [_]f32{ left, centerW, right };
    const dstH = [_]f32{ top, centerH, bottom };

    for (0..3) |row| {
        for (0..3) |col| {
            const srcPos = Vector2.xy(srcX[col], srcY[row]);
            const srcSize = Vector2.xy(srcW[col], srcH[row]);
            const pos = Vector2.xy(dstX[col], dstY[row]);
            drawImage(nine.image.sub(.init(srcPos, srcSize)), pos, .{
                .size = .xy(dstW[col], dstH[row]),
            });
        }
    }
}

// 使用相机栈绘制图片，栈为空时不做相机转换。
pub fn drawImage(image: Image, pos: Vector2, option: Option) void {
    drawCamera(image, pos, camera.stack.getLastOrNull(), option);
}

// 忽略相机栈，按指定相机转换；null 直接提交，仍应用批次渲染相机。
pub fn drawCamera(
    image: Image,
    pos: Vector2,
    source: ?camera.Camera,
    option: Option,
) void {
    const cmd = ensureDraw(image);
    const size = option.size orelse image.size;
    // 中心使用缩放前的尺寸，改变 scale 时保持位置不变。
    var center = pos.add(size.mul(option.pivot.sub(option.anchor)));
    var drawSize = size.mul(option.scale);
    if (source) |view| {
        drawSize = drawSize.mul(view.scale.div(cmd.camera.scale));
        center = cmd.camera.toWorld(view.toWindow(center));
    }

    assets.gpu.addVertex(Vertex{
        .position = center,
        .layer = image.layer,
        .filter = image.filter,
        .radian = option.radian,
        .size = drawSize,
        .pivot = option.pivot,
        .uvRect = option.uvRect orelse image.uvRect(),
        .color = option.color,
        .addColor = option.addColor,
        .skew = option.skew,
        .snap = option.snap orelse snap,
    });
}

pub fn flush() void {
    endDrawCommand();

    // 在渲染通道开始前提交图片和顶点，保存可能扩容后的缓冲句柄。
    vertexBuffer = assets.gpu.upload(vertexBuffer);

    var pipeline: sk.gfx.Pipeline = .{}; // 当前渲染通道已绑定的流水线。
    var activePass, var flipY = .{ false, false };
    var viewport: math.Rect = undefined;
    var scissor: math.Rect = undefined;
    for (commands.items) |cmd| {
        switch (cmd) {
            .target => |target| {
                if (activePass) graphics.endPass();
                flipY = target.pass.target != null and
                    !sk.gfx.queryFeatures().origin_top_left;
                viewport = graphics.beginPass(target.color, target.pass);
                scissor = viewport;
                pipeline = .{};
                activePass = true;
            },
            .viewport => |view| {
                viewport, scissor = .{ view, view };
                graphics.applyViewport(view.min, view.size);
                // 切换视口时恢复完整裁剪，避免沿用旧视口的局部裁剪。
                graphics.applyScissor(view.min, view.size);
            },
            .scissor => |clip| {
                var pos = clip.min;
                // 离屏翻转后，原来的底部间距成为顶部间距。
                if (flipY) {
                    const gap = viewport.max().y - clip.max().y;
                    pos.y = viewport.min.y + gap;
                }
                scissor = .init(pos, clip.size);
                graphics.applyScissor(pos, clip.size);
            },
            .draw => |draw| doDraw(draw, viewport.size, flipY, &pipeline),
            .custom => |custom| {
                custom.func(custom.ctx);
                pipeline = .{};
                graphics.applyViewport(viewport.min, viewport.size);
                graphics.applyScissor(scissor.min, scissor.size);
            },
        }
    }
    flushed = true;
}

pub fn endDraw() void {
    std.debug.assert(commands.items.len != 0);

    if (!flushed) flush();
    graphics.endPass();
    graphics.commit();
    commandPeak = @max(commandPeak, commands.items.len);
}

// 提交一个绘制批次，并更新当前流水线。
fn doDraw(
    cmd: DrawCommand,
    viewportSize: Vector2,
    flipY: bool,
    pipeline: *sk.gfx.Pipeline,
) void {
    // 只缓存流水线。
    // bindings 包含实例起点 offset，每个命令可能不同。
    // uniforms 依赖相机、目标翻转和纹理大小，保持逐次提交。
    if (pipeline.id != cmd.pipeline.id) {
        sk.gfx.applyPipeline(cmd.pipeline);
        pipeline.* = cmd.pipeline;
    }

    // Sokol 将浮点视口截断为整数，对齐必须使用同样的实际像素尺寸。
    const pixels = Vector2.xy(@trunc(viewportSize.x), @trunc(viewportSize.y));
    if (pixels.x <= 0 or pixels.y <= 0) return;
    const size = graphics.queryViewSize(cmd.view);
    const scale = cmd.camera.scale.mul(.xy(2, -2)).div(cmd.size);
    const offset = cmd.camera.position.mul(scale).neg();
    var rowY = [_]f32{ 0, scale.y, offset.y + 1, pixels.y / 2 };
    if (flipY) rowY[1], rowY[2] = .{ -rowY[1], -rowY[2] };
    const uniforms = sk.gfx.asRange(&shader.VsParams{
        // 投影行的 w 保存半视口尺寸。
        .transformX = .{ scale.x, 0, offset.x - 1, pixels.x / 2 },
        .transformY = rowY,
        // xy 为纹理尺寸倒数，zw 为一个像素对应的裁剪坐标步长。
        .textureVec = .{ 1 / size.x, 1 / size.y, 2 / pixels.x, 2 / pixels.y },
    });
    sk.gfx.applyUniforms(shader.UB_vs_params, uniforms);

    // 绑定组
    var bindings = sk.gfx.Bindings{};
    bindings.views[0] = cmd.view;
    bindings.vertex_buffers[0] = vertexBuffer;
    bindings.vertex_buffer_offsets[0] = @intCast(cmd.start * @sizeOf(Vertex));
    if (options.samplers) {
        bindings.samplers[0] = assets.sampler.nearest;
        bindings.samplers[1] = assets.sampler.linear;
    } else {
        bindings.samplers[0] = assets.sampler.get(cmd.filter);
    }
    sk.gfx.applyBindings(bindings);

    // 绘制
    sk.gfx.draw(0, 4, @intCast(cmd.end.? - cmd.start));
}
