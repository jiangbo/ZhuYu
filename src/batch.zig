const std = @import("std");
const sk = @import("sokol");
const shader = @import("shader");
const options = @import("options");

const zhu = @import("zhu.zig");
const graphics = @import("graphics.zig");
const assets = @import("assets.zig");
const camera = @import("camera.zig");

const Image = graphics.Image;
const ImageId = graphics.ImageId;
const Color = graphics.Color;
const RenderPass = graphics.RenderPass;
const Vector2 = zhu.Vector2;
const Vertex = graphics.Vertex;

pub const Option = graphics.DrawOption;

pub const Command = union(enum) {
    target: TargetCommand, // 渲染目标
    viewport: zhu.Rect, // 目标像素区域。
    scissor: zhu.Rect, // 目标像素裁剪，离屏翻转在提交时处理。
    draw: DrawCommand, // 绘制命令
};

pub const TargetCommand = struct { color: Color, pass: RenderPass };
pub const DrawCommand = struct {
    start: u32 = 0, // 起始顶点索引
    end: usize = 0, // 结束顶点索引
    view: graphics.View = .{}, // 纹理视图
    camera: camera.Camera, // 本批次的基准相机快照。
    size: Vector2, // 本批次绘制的逻辑尺寸。
};

pub var whiteImage: graphics.Image = undefined;
pub var circleImage: graphics.Image = undefined;
// 图片绘制是否默认对齐顶点到目标像素。
pub var snap: bool = false;

// 命令借用调用方提供的固定缓冲区。
pub var commands: std.ArrayList(Command) = .empty;

var vertexBuffer: sk.gfx.Buffer = .{}; // 上传后用于绘制的顶点缓冲。
var defaultPipeline: sk.gfx.Pipeline = undefined; // 默认图片流水线。
var flushed = false;

// 命令缓冲区由调用方持有，必须保持有效且容量足够。
// image 用于圆形等基础图形；不绘制基础图形时可传 null。
pub fn init(cmds: []Command, image: ?Image) void {
    commands = .initBuffer(cmds);
    const shaderDesc = shader.quadShaderDesc(sk.gfx.queryBackend());
    defaultPipeline = graphics.createPipeline(shaderDesc);

    // 调用方提供圆形图片，其中心区域必须为白色。
    // 建议与其他素材放在同一图集，避免绘制基础图形时切换纹理、打断合批。
    circleImage = image orelse return;
    const rect = zhu.Rect.init(.zero, circleImage.size);
    whiteImage = circleImage.sub(rect.centerScale(0.25));
}

// 开始记录本帧绘制和首个目标，GPU pass 在 flush 时开启。
pub fn beginDraw(color: Color, pass: RenderPass) void {
    assets.beginDraw();
    commands.clearRetainingCapacity();
    flushed = false;
    camera.state.camera = camera.main;
    useTarget(color, pass);
}

pub fn useTarget(color: Color, pass: graphics.RenderPass) void {
    endDrawCommand();
    commands.appendAssumeCapacity(.{
        .target = .{ .color = color, .pass = pass },
    });
    camera.state.viewRect = pass.queryViewport();
    camera.state.size = pass.querySize();
}

// 设置目标像素区域和对应的逻辑尺寸，同时重置裁剪区域。
pub fn useViewport(rect: zhu.Rect, size: Vector2) void {
    endDrawCommand();
    camera.state.viewRect = rect;
    camera.state.size = size;
    commands.appendAssumeCapacity(.{ .viewport = rect });
}

// 裁剪使用当前视口的逻辑坐标，不受相机影响；null 恢复完整视口。
pub fn useScissor(rect: ?zhu.Rect) void {
    endDrawCommand();
    var clip = camera.state.viewRect;
    if (rect) |area| {
        const scale = clip.size.div(camera.state.size);
        clip.min = clip.min.add(area.min.mul(scale));
        clip.size = area.size.mul(scale);
    }
    commands.appendAssumeCapacity(.{ .scissor = clip });
}

// 存在未结束的绘制命令时结束它，下一次绘制会创建新命令。
pub fn endDrawCommand() void {
    if (currentDraw()) |draw| draw.end = assets.frameStats.vertex;
}

fn currentDraw() ?*DrawCommand {
    if (commands.items.len == 0) return null;
    switch (commands.items[commands.items.len - 1]) {
        .draw => |*draw| return if (draw.end != 0) null else draw,
        else => return null,
    }
}

fn addCommand(image: Image) *DrawCommand {
    endDrawCommand();
    commands.appendAssumeCapacity(.{ .draw = .{
        .start = @intCast(assets.frameStats.vertex),
        .view = image.view,
        .camera = camera.state.camera,
        .size = camera.state.size,
    } });
    return currentDraw().?;
}

// 直接提交调用方准备好的顶点，不修改其绘制设置。
pub fn drawVertices(items: []const Vertex, image: ?Image) void {
    if (image) |img| {
        const cmd = currentDraw() orelse addCommand(img);
        // 自动分批只比较纹理视图，不比较采样器或其它状态。
        if (cmd.view.id != img.view.id) _ = addCommand(img);
    }
    assets.gpu.addVertices(items);
}

pub fn drawDebug(rect: zhu.Rect) void {
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

pub fn drawRectBorder(rect: zhu.Rect, width: f32, c: Color) void {
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
pub fn drawRect(rect: zhu.Rect, option: RectOption) void {
    drawImage(whiteImage, rect.min, .{
        .size = rect.size,
        .color = option.color,
        .radian = option.radian,
    });
}

pub fn drawCircle(position: Vector2, option: Option) void {
    drawImage(circleImage, position, option);
}

pub fn drawAxisCapsule(rect: zhu.Rect, color: Color) void {
    if (rect.size.x <= 0 or rect.size.y <= 0) return;

    if (rect.size.x >= rect.size.y) {
        const radius = rect.size.y * 0.5;
        const half = circleImage.size.mul(.xy(0.5, 1));
        const size = Vector2.xy(radius, rect.size.y);

        var image = circleImage.sub(.init(.zero, half));
        drawImage(image, rect.min, .{ .size = size, .color = color });

        const middleRect = zhu.Rect.init(
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

    const middleRect = zhu.Rect.init(
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

pub fn drawNine(nine: graphics.NineImage, rect: zhu.Rect) void {
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
    var cmd = currentDraw() orelse addCommand(image);
    if (cmd.view.id != image.view.id) cmd = addCommand(image);

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
        .filter = option.filter orelse image.filter,
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
    var viewport: zhu.Rect = undefined;
    for (commands.items) |cmd| {
        switch (cmd) {
            .target => |target| {
                if (activePass) graphics.endPass();
                flipY = target.pass.target != null and
                    !sk.gfx.queryFeatures().origin_top_left;
                viewport = graphics.beginPass(target.color, target.pass);
                pipeline = .{};
                activePass = true;
            },
            .viewport => |view| {
                viewport = view;
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
                graphics.applyScissor(pos, clip.size);
            },
            .draw => |draw| doDraw(draw, viewport.size, flipY, &pipeline),
        }
    }
    flushed = true;
}

pub fn endDraw() void {
    std.debug.assert(commands.items.len != 0);

    if (!flushed) flush();
    graphics.endPass();
    graphics.commit();
}

// 提交一个绘制批次，并更新当前流水线。
fn doDraw(
    cmd: DrawCommand,
    viewportSize: Vector2,
    flipY: bool,
    pipeline: *sk.gfx.Pipeline,
) void {
    // 未指定流水线时使用默认图片流水线。
    const info = assets.view.get(cmd.view);
    const selected = info.pipeline orelse defaultPipeline;
    // 只缓存流水线。
    // bindings 包含实例起点 offset，每个命令可能不同。
    // uniforms 依赖相机、目标翻转和纹理大小，保持逐次提交。
    if (pipeline.id != selected.id) {
        sk.gfx.applyPipeline(selected);
        pipeline.* = selected;
    }

    // Sokol 将浮点视口截断为整数，对齐必须使用同样的实际像素尺寸。
    const pixels = Vector2.xy(@trunc(viewportSize.x), @trunc(viewportSize.y));
    if (pixels.x <= 0 or pixels.y <= 0) return;
    const size = graphics.queryViewSize(cmd.view);
    const scale = cmd.camera.scale.mul(.xy(2, -2)).div(cmd.size);
    var offset = cmd.camera.position.mul(scale).neg();
    if (camera.snap) {
        // 在实际视口像素中取整平移量，不修改相机的逻辑位置。
        const half = pixels.scale(0.5);
        offset = offset.mul(half).round().div(half);
    }
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
        bindings.samplers[0] = info.sampler;
    }
    sk.gfx.applyBindings(bindings);

    // 绘制
    sk.gfx.draw(0, 4, @intCast(cmd.end - cmd.start));
}
