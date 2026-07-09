const std = @import("std");
const builtin = @import("builtin");

const sk = @import("sokol");
const math = @import("math.zig");
const assets = @import("assets.zig");
const camera = @import("camera.zig");
const em = @import("internal/c.zig").em;
const input = @import("input.zig");
const memory = @import("internal/memory.zig");
const text = @import("text.zig");

pub const Event = sk.app.Event;

/// 缩放模式枚举
pub const ScaleEnum = enum {
    none, // 无缩放，使用原始尺寸
    stretch, // 拉伸缩放，忽略宽高比填满屏幕
    fit, // 适配缩放，保持宽高比可能有黑边
    fill, // 填充缩放，保持宽高比可能超出屏幕
    integer, // 整数缩放，整数倍数（无滤镜失真）
};

pub const Info = struct {
    title: [:0]const u8, // 窗口标题
    size: math.Vector, // 窗口大小
    logicSize: ?math.Vector = null, // 逻辑大小，默认和窗口大小相同
    scaleEnum: ScaleEnum = .stretch, // 缩放模式
    disableIME: bool = true, // 禁用输入法
    alignment: math.Vector = .center, // 对齐方式
    maxFileSize: usize = 1 * 1024 * 1024, // 最大加载文件大小
};

pub var size: math.Vector = .zero;
pub var clientSize: math.Vector = .zero;
pub var viewRect: math.Rect = undefined;
pub var alignment: math.Vector2 = .center; // 默认居中
var scaleEnum: ScaleEnum = .stretch; // 当前缩放模式
var io: std.Io = undefined;

pub extern "Imm32" fn ImmDisableIME(i32) std.os.windows.BOOL;

pub fn call(object: anytype, comptime name: []const u8, args: anytype) void {
    if (@hasDecl(object, name)) @call(.auto, @field(object, name), args);
}

const root = @import("root");
pub fn run(io_: std.Io, gpa: std.mem.Allocator, info: Info) void {
    sk.time.setup();
    size = info.logicSize orelse info.size;
    camera.init(size);
    viewRect = .init(.zero, size);
    alignment = info.alignment;
    scaleEnum = info.scaleEnum;
    io = io_;
    assets.init(io, gpa, info.maxFileSize);

    if (info.disableIME and builtin.os.tag == .windows) {
        _ = ImmDisableIME(-1);
    }

    sk.app.run(.{
        .window_title = info.title,
        .width = @intFromFloat(info.size.x),
        .height = @intFromFloat(info.size.y),
        .init_cb = windowInit,
        .event_cb = windowEvent,
        .frame_cb = windowFrame,
        .cleanup_cb = windowDeinit,
        .allocator = @bitCast(memory.skAllocator),
        .high_dpi = true,
    });
}

export fn windowInit() void {
    computeViewRect();
    sk.gfx.setup(.{
        .environment = sk.glue.environment(),
        .logger = .{ .func = sk.log.func },
        .allocator = memory.skAllocator,
    });
    math.random.init(sk.time.now());
    call(root, "init", .{memory.allocator});
}

pub var mouse: math.Vector = .zero;
pub var resized: bool = false;

export fn windowEvent(event: ?*const Event) void {
    if (event) |ev| {
        input.handle(ev);
        if (ev.type == .MOUSE_MOVE) {
            const position = input.mouse.raw.sub(viewRect.min);
            mouse = position.mul(size).div(viewRect.size);
        } else if (ev.type == .RESIZED) resized = true;

        call(root, "event", .{ev});
    }
}

pub fn computeViewRect() void {
    clientSize = .xy(sk.app.widthf(), sk.app.heightf());
    const ratio = clientSize.div(size);
    switch (scaleEnum) {
        .none => {
            viewRect = .init(clientSize.sub(size).mul(alignment), size);
        },
        .stretch => viewRect = .init(.zero, clientSize),
        .fit => {
            const minSize = size.scale(@min(ratio.x, ratio.y));
            const position = clientSize.sub(minSize).mul(alignment);
            viewRect = .init(position, minSize);
        },
        .fill => {
            const maxSize = size.scale(@max(ratio.x, ratio.y));
            const position = clientSize.sub(maxSize).mul(alignment);
            viewRect = .init(position, maxSize);
        },
        .integer => {
            const scale = @min(ratio.x, ratio.y);
            const usedScale = if (scale < 1) scale else @trunc(scale);
            const intSize = size.scale(usedScale);
            const position = clientSize.sub(intSize).mul(alignment);
            viewRect = .init(position, intSize);
        },
    }
    resized = false;
}

pub var frameTicks: u64 = 0;
export fn windowFrame() void {
    const frameStart = sk.time.now();
    sk.fetch.dowork();
    if (resized) computeViewRect();
    const delta: f32 = @floatCast(sk.app.frameDuration());
    call(root, "frame", .{delta});
    input.update();
    frameTicks = sk.time.since(frameStart);
}

export fn windowDeinit() void {
    call(root, "deinit", .{memory.allocator});
    sk.gfx.shutdown();
    assets.deinit();
}

pub fn timestamp() std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .real);
}

pub const showCursor = sk.app.showMouse;
pub const toggleFullScreen = sk.app.toggleFullscreen;
pub const frameCount = sk.app.frameCount;

const Dir = std.Io.Dir;
pub fn statFileTime(path: [:0]const u8) i128 {
    const file = Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);

    const stat = file.stat(io) catch return 0;
    return @intCast(stat.mtime.toNanoseconds());
}

pub fn readBuffer(path: [:0]const u8, buffer: []u8) ![:0]u8 {
    const buf = buffer[0 .. buffer.len - 1];
    if (@import("builtin").target.os.tag == .emscripten) {
        return switch (try em.load(path, buf)) {
            .loaded => |content| terminateBuffer(buffer, content.len),
            .tooSmall => error.BufferTooSmall,
        };
    }
    const content = try Dir.cwd().readFile(io, path, buf);
    return terminateBuffer(buffer, content.len);
}

const Allocator = std.mem.Allocator;
pub fn readAll(gpa: Allocator, path: [:0]const u8) ![:0]u8 {
    if (@import("builtin").target.os.tag == .emscripten) {
        var buffer: [1024]u8 = undefined;
        return switch (try em.load(path, &buffer)) {
            .loaded => |content| try gpa.dupeZ(u8, content),
            .tooSmall => |len| readFromJs(gpa, path, len),
        };
    }
    return try Dir.cwd().readFileAllocOptions( //
        io, path, gpa, .unlimited, .of(u8), 0);
}

pub fn Zon(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

pub const ZonOption = struct { ignore: bool = false };
// 读取 ZON 文件，返回带 arena 生命周期的包装对象。
pub fn readZon(T: type, path: [:0]const u8, ops: ZonOption) !Zon(T) {
    const gpa = memory.allocator.raw;
    const source = try readAll(gpa, path);
    defer gpa.free(source);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const arenaAllocator = arena.allocator();
    const option: std.zon.parse.Options = .{
        .ignore_unknown_fields = ops.ignore,
        .free_on_error = false,
    };
    const value = try std.zon.parse.fromSliceAlloc(T, //
        arenaAllocator, source, null, option);
    return .{ .value = value, .arena = arena };
}

pub fn saveZon(path: [:0]const u8, value: anytype) !void {
    const gpa = memory.allocator.raw;
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    try std.zon.stringify.serialize(value, .{}, &writer.writer);
    try saveAll(path, writer.writer.buffered());
}

fn terminateBuffer(buffer: []u8, len: usize) [:0]u8 {
    buffer[len] = 0;
    return buffer[0..len :0];
}

fn readFromJs(gpa: Allocator, path: [:0]const u8, len: usize) ![:0]u8 {
    const large = try gpa.alloc(u8, len + 1);
    errdefer gpa.free(large);
    return switch (try em.load(path, large[0..len])) {
        .loaded => |content| terminateBuffer(large, content.len),
        .tooSmall => error.BufferTooSmall,
    };
}

pub fn saveAll(path: [:0]const u8, content: []const u8) !void {
    if (@import("builtin").target.os.tag == .emscripten) {
        return em.save(path, content);
    }

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(io, dir);
    }

    var file = try cwd.createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    try file.writeStreamingAll(io, content);
}

pub fn exit() void {
    sk.app.requestQuit();
}

pub const Cursor = sk.app.MouseCursor;
pub const setCursor = sk.app.setMouseCursor;
pub const CursorDesc = extern struct {
    cursor: Cursor = .CUSTOM_1,
    offset: extern struct { x: i16 = 0, y: i16 = 0 } = .{},
    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
    }
};
pub fn loadCursor(path: [:0]const u8, desc: CursorDesc) void {
    assets.loadIcon(path, @bitCast(desc), mouseCallback);
}

fn mouseCallback(handle: u64, icon: assets.Icon) void {
    const cursorDesc: CursorDesc = @bitCast(handle);
    _ = sk.app.bindMouseCursorImage(cursorDesc.cursor, .{
        .pixels = @bitCast(sk.gfx.asRange(icon.data)),
        .width = icon.width,
        .height = icon.height,
        .cursor_hotspot_x = cursorDesc.offset.x,
        .cursor_hotspot_y = cursorDesc.offset.y,
    });
}

pub fn useCursor(path: [:0]const u8, desc: CursorDesc) void {
    assets.loadIcon(path, @bitCast(desc), struct {
        fn callback(handle: u64, icon: assets.Icon) void {
            mouseCallback(handle, icon);
            const cursorDesc: CursorDesc = @bitCast(handle);
            setCursor(cursorDesc.cursor);
        }
    }.callback);
}

pub fn useWindowIcon(path: [:0]const u8) void {
    assets.loadIcon(path, 0, struct {
        fn callback(_: u64, icon: assets.Icon) void {
            var desc: sk.app.IconDesc = .{};
            desc.images[0] = .{
                .pixels = @bitCast(sk.gfx.asRange(icon.data)),
                .width = icon.width,
                .height = icon.height,
            };
            sk.app.setIcon(desc);
        }
    }.callback);
}

pub fn drawCenter(str: text.String, y: f32, option: text.Option) void {
    const textSize = text.measure(str, option);
    const pos = size.mul(.xy(0.5, y)).sub(.xy(textSize.x / 2, 0));
    text.draw(str, pos, option);
}
