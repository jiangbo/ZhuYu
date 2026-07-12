const std = @import("std");

const sk = @import("sokol");
const math = @import("math.zig");
const shader = @import("shader");
const graphics = @import("graphics.zig");
const assets = @import("assets.zig");
const camera = @import("camera.zig");

const Image = graphics.Image;
const ImageId = graphics.ImageId;
const Color = graphics.Color;
const RenderPass = graphics.RenderPass;
const Vector2 = math.Vector2;

pub const Vertex = extern struct {
    position: math.Vector2 = .zero, // 顶点坐标
    layer: f32 = 0, // 绘制层级
    radian: f32 = 0, // 旋转弧度
    size: math.Vector2, // 大小
    pivot: math.Vector2 = .zero, // 旋转中心
    uvRect: math.Vector4, // 纹理 UV 区域
    color: graphics.Color = .white, // 顶点颜色
};

pub const Option = struct {
    size: ?Vector2 = null, // 大小
    scale: Vector2 = .one, // 缩放
    anchor: Vector2 = .zero, // 锚点
    pivot: Vector2 = .center, // 旋转中心
    radian: f32 = 0, // 旋转弧度
    uvRect: ?math.Vector4 = null, // 纹理 UV 区域
    color: graphics.Color = .white, // 颜色
    camera: ?camera.Camera = null, // 指定绘制使用的相机
};

pub const Command = union(enum) {
    target: TargetCommand, // 渲染目标
    scissor: ?math.Rect, // 裁剪区域
    draw: DrawCommand, // 绘制命令
};

pub const TargetCommand = struct { color: Color, pass: RenderPass };
pub const DrawCommand = struct {
    start: u32 = 0, // 起始顶点索引
    end: usize = 0, // 结束顶点索引
    view: graphics.View = .{}, // 纹理视图
    camera: camera.Camera, // 绘制命令相机
    size: Vector2, // 视口大小
    pipeline: sk.gfx.Pipeline, // 渲染流水线
    sampler: sk.gfx.Sampler = .{}, // 采样器
};

pub var whiteImage: graphics.Image = undefined;
pub var circleImage: graphics.Image = undefined;

pub var vertices: std.ArrayList(Vertex) = .empty;
pub var commands: std.ArrayList(Command) = .empty;

var vertexHandle: sk.gfx.Buffer = undefined;
var pipeline: sk.gfx.Pipeline = undefined;
var drawState: DrawCommand = undefined;
var flushed = false;

pub fn init(vertex: []Vertex, cmds: []Command) void {
    vertices = .initBuffer(vertex);
    commands = .initBuffer(cmds);
    if (@import("builtin").is_test) return;

    const shaderDesc = shader.quadShaderDesc(sk.gfx.queryBackend());
    pipeline = createPipeline(shaderDesc);
    vertexHandle = sk.gfx.makeBuffer(.{
        .size = @sizeOf(Vertex) * vertex.len,
        .usage = .{ .stream_update = true },
    });
}

pub fn beginDraw() void {
    graphics.stats = .{};
    vertices.clearRetainingCapacity();
    commands.clearRetainingCapacity();
    flushed = false;
    drawState = .{
        .camera = camera.main,
        .size = camera.size,
        .pipeline = pipeline,
    };
}

pub fn useTarget(color: Color, pass: graphics.RenderPass) void {
    if (currentDraw()) |draw| draw.end = vertices.items.len;
    commands.appendAssumeCapacity(.{
        .target = .{ .color = color, .pass = pass },
    });
}

// 设置逻辑坐标裁剪区域，null 恢复当前视口。
pub fn useScissor(rect: ?math.Rect) void {
    if (currentDraw()) |draw| draw.end = vertices.items.len;
    commands.appendAssumeCapacity(.{ .scissor = rect });
}

pub fn usePipeline(value: ?sk.gfx.Pipeline) void {
    const next = value orelse pipeline;
    if (drawState.pipeline.id == next.id) return;

    endCommand();
    drawState.pipeline = next;
}

// 返回后续绘制命令使用的流水线。
pub fn queryPipeline() sk.gfx.Pipeline {
    return drawState.pipeline;
}

// 结束当前绘制命令，下一次绘制会创建新命令。
pub fn endCommand() void {
    if (currentDraw()) |draw| draw.end = vertices.items.len;
}

fn uploadVertices() void {
    if (vertices.items.len == 0) return;
    const buffer = sk.gfx.asRange(vertices.items);
    _ = sk.gfx.updateBuffer(vertexHandle, buffer);
}

fn currentDraw() ?*DrawCommand {
    if (commands.items.len == 0) return null;
    switch (commands.items[commands.items.len - 1]) {
        .draw => |*draw| return if (draw.end != 0) null else draw,
        else => return null,
    }
}

fn addCommand(image: Image) *DrawCommand {
    if (currentDraw()) |draw| draw.end = vertices.items.len;
    var draw = drawState;
    draw.start = @intCast(vertices.items.len);
    draw.view = image.view;
    draw.sampler = image.sampler;
    commands.appendAssumeCapacity(.{ .draw = draw });
    return currentDraw().?;
}

pub fn drawVertices(items: []const Vertex, image: ?Image) void {
    if (image) |img| {
        const cmd = currentDraw() orelse addCommand(img);
        if (cmd.view.id != img.view.id) _ = addCommand(img);
    }
    vertices.appendSliceAssumeCapacity(items);
}

pub fn drawDebug(rect: math.Rect) void {
    drawRect(rect, .{ .color = .rgba(1, 0, 1, 0.4) });
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

pub fn drawImage(image: Image, pos: Vector2, option: Option) void {
    var cmd = currentDraw() orelse addCommand(image);
    if (cmd.view.id != image.view.id) cmd = addCommand(image);

    const size = option.size orelse image.size;
    var drawPos, var drawSize = .{ pos, size.mul(option.scale) };
    if (option.camera orelse camera.stack.getLastOrNull()) |source| {
        drawSize = drawSize.mul(source.scale.div(cmd.camera.scale));
        drawPos = cmd.camera.toWorld(source.toWindow(pos));
    }

    vertices.appendAssumeCapacity(Vertex{
        .position = drawPos.sub(drawSize.mul(option.anchor)),
        .layer = image.layer,
        .radian = option.radian,
        .size = drawSize,
        .pivot = option.pivot,
        .uvRect = option.uvRect orelse image.uvRect(),
        .color = option.color,
    });
}

pub fn flush() void {
    if (currentDraw()) |draw| draw.end = vertices.items.len;

    uploadVertices();
    var activePass, var flipY = .{ false, false };
    var viewport: math.Rect = undefined;
    for (commands.items) |cmd| {
        switch (cmd) {
            .target => |target| {
                if (activePass) graphics.endPass();
                flipY = target.pass.target != null and
                    !sk.gfx.queryFeatures().origin_top_left;
                viewport = graphics.beginPass(target.color, target.pass);
                drawState.pipeline = .{};
                activePass = true;
            },
            .scissor => |rect| applyScissor(rect, viewport, drawState.size),
            .draw => |draw| doDraw(draw, flipY),
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

fn applyScissor(rect: ?math.Rect, view: math.Rect, size: Vector2) void {
    const area = rect orelse math.Rect.init(.zero, size);
    const ratio = view.size.div(size);
    const pos = view.min.add(area.min.mul(ratio));
    const clip = area.size.mul(ratio);
    sk.gfx.applyScissorRectf(pos.x, pos.y, clip.x, clip.y, true);
}

fn doDraw(cmd: DrawCommand, flipY: bool) void {
    // 只缓存流水线。
    // bindings 包含实例起点 offset，每个命令可能不同。
    // uniforms 依赖相机、目标翻转和纹理大小，保持逐次提交。
    if (drawState.pipeline.id != cmd.pipeline.id) {
        sk.gfx.applyPipeline(cmd.pipeline);
        drawState.pipeline = cmd.pipeline;
    }

    // 处理 uniform 变量
    const size = graphics.queryViewSize(cmd.view);
    const scale = cmd.camera.scale.mul(.xy(2, -2)).div(cmd.size);
    const offset = cmd.camera.position.mul(scale).neg();
    var rowY = [_]f32{ 0, scale.y, offset.y + 1, 0 };
    if (flipY) rowY[1], rowY[2] = .{ -rowY[1], -rowY[2] };
    const uniforms = sk.gfx.asRange(&shader.VsParams{
        .transformX = .{ scale.x, 0, offset.x - 1, 0 },
        .transformY = rowY,
        .textureVec = .{ 1 / size.x, 1 / size.y, 1, 1 },
    });
    sk.gfx.applyUniforms(shader.UB_vs_params, uniforms);

    // 绑定组
    var bindings = sk.gfx.Bindings{};
    bindings.views[0] = cmd.view;
    bindings.vertex_buffers[0] = vertexHandle;
    bindings.vertex_buffer_offsets[0] = @intCast(cmd.start * @sizeOf(Vertex));
    bindings.samplers[0] = cmd.sampler;
    sk.gfx.applyBindings(bindings);

    // 绘制
    sk.gfx.draw(0, 4, @intCast(cmd.end - cmd.start));
}

pub fn createPipeline(shaderDesc: sk.gfx.ShaderDesc) sk.gfx.Pipeline {
    var vertexLayout = sk.gfx.VertexLayoutState{};

    vertexLayout.attrs[0].format = .FLOAT2;
    vertexLayout.attrs[1].format = .FLOAT;
    vertexLayout.attrs[2].format = .FLOAT;
    vertexLayout.attrs[3].format = .FLOAT2;
    vertexLayout.attrs[4].format = .FLOAT2;
    vertexLayout.attrs[5].format = .FLOAT4;
    vertexLayout.attrs[6].format = .FLOAT4;
    vertexLayout.buffers[0].step_func = .PER_INSTANCE;

    const shaderHandle = sk.gfx.makeShader(shaderDesc);
    assets.gpu.addShader(shaderHandle);

    const result = sk.gfx.makePipeline(.{
        .shader = shaderHandle,
        .layout = vertexLayout,
        .primitive_type = .TRIANGLE_STRIP,
        .colors = init: {
            var c: [8]sk.gfx.ColorTargetState = @splat(.{});
            c[0] = .{ .blend = .{
                .enabled = true,
                .src_factor_rgb = .SRC_ALPHA,
                .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                .src_factor_alpha = .ONE,
                .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            } };
            break :init c;
        },
    });
    assets.gpu.addPipeline(result);
    return result;
}
