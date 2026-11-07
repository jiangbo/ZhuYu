const std = @import("std");
const sk = @import("sokol");

const zhu = @import("../zhu.zig");
const assets = @import("../assets.zig");
const audio = @import("../audio.zig");
const batch = @import("../batch.zig");
const camera = @import("../camera.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const window = @import("../window.zig");

const Color = graphics.Color;
const Vector2 = zhu.Vector2;
const Rect = zhu.Rect;

// 是否启用调试面板绘制。
pub var enabled: bool = false;

// 每帧调用，松开指定按键时切换调试面板。
pub fn toggle(key: window.key.Code) void {
    if (window.key.released(key)) enabled = !enabled;
}

pub const Row = struct {
    label: []const u8,
    left: []const u8,
    right: []const u8 = "",
};

const Columns = struct {
    label: std.Io.Writer,
    left: std.Io.Writer,
    right: std.Io.Writer,
};

// ZON 热重载暂时停用。
// var allocator: std.mem.Allocator = undefined;
// var io: std.Io = undefined;
//
// // 返回可热重载的 ZON 数据指针。首次调用会从文件读取。
// pub fn zon(comptime T: type, comptime path: [:0]const u8) *T {
//     const file = ZonFile(T, path);
//     if (file.parsed == null and !file.reload()) {
//         std.debug.panic("zon load failed: {s}", .{path});
//     }
//     const result = zonMap.getOrPut(allocator, path) //
//         catch zhu.oom();
//     if (!result.found_existing) {
//         result.value_ptr.* = .{
//             .path = path,
//             .mtime = statFileTime(path),
//             .reload = file.reload,
//             .deinit = file.deinit,
//         };
//     }
//
//     return &file.parsed.?.value;
// }
//
// // 重新加载有变化的 ZON 文件。
// pub fn reloadZon() void {
//     var iterator = zonMap.valueIterator();
//     while (iterator.next()) |entry| {
//         const mtime = statFileTime(entry.path);
//         if (mtime == 0 or mtime == entry.mtime) continue;
//
//         const loaded = entry.reload();
//         entry.mtime = mtime;
//         if (loaded) std.log.info("zon reloaded: {s}", .{entry.path});
//     }
// }
//
// // 释放调试热重载保存的 ZON 数据。
// pub fn deinit() void {
//     var iterator = zonMap.valueIterator();
//     while (iterator.next()) |entry| entry.deinit();
//     zonMap.deinit(allocator);
// }
//
// const ZonEntry = struct {
//     path: [:0]const u8,
//     mtime: i128,
//     reload: *const fn () bool,
//     deinit: *const fn () void,
// };
//
// var zonMap: std.StringHashMapUnmanaged(ZonEntry) = .empty;
//
// // 查询热重载文件的修改时间，路径相对于当前工作目录。
// fn statFileTime(path: [:0]const u8) i128 {
//     const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
//     defer file.close(io);
//     const stat = file.stat(io) catch return 0;
//     return @intCast(stat.mtime.toNanoseconds());
// }
//
// fn ZonFile(comptime T: type, comptime path: [:0]const u8) type {
//     return struct {
//         // 每次重载使用独立 arena，解析失败时保留上一次的数据。
//         var parsed: ?struct { value: T, arena: std.heap.ArenaAllocator } = null;
//
//         fn reload() bool {
//             const gpa = allocator;
//             const source = std.Io.Dir.cwd().readFileAllocOptions(
//                 io,
//                 path,
//                 gpa,
//                 .unlimited,
//                 .of(u8),
//                 0,
//             ) catch |err| {
//                 std.log.err("zon reload failed: {s}: {}", .{ path, err });
//                 return false;
//             };
//             defer gpa.free(source);
//
//             var arena = std.heap.ArenaAllocator.init(gpa);
//             var diagnostics: std.zon.parse.Diagnostics = undefined;
//             const value = std.zon.parse.fromSlice(T, .{
//                 .gpa = gpa,
//                 .arena = arena.allocator(),
//                 .source = source,
//                 .diagnostics = &diagnostics,
//             }) catch |err| {
//                 arena.deinit();
//                 std.log.err("zon reload failed: {s}: {}", .{ path, err });
//                 return false;
//             };
//
//             if (parsed) |*old| old.arena.deinit();
//             parsed = .{ .value = value, .arena = arena };
//             return true;
//         }
//
//         fn deinit() void {
//             if (parsed) |*old| old.arena.deinit();
//         }
//     };
// }
//
var last: u64 = 0;
var fps: u64 = 0;
var fpsFrame: u64 = 0;
var start: u64 = 0;
var frameTime: f64 = 0;
var usedTime: f64 = 0;

pub const Option = struct {
    position: Vector2 = .xy(10, 10), // 游戏画面左上角起算的逻辑坐标。
    extra: []const Row = &.{},
};

// 在当前游戏视口内横向铺满并留边，高度按文字内容计算。
pub fn draw(option: Option) void {
    if (!enabled) return;
    const time = sk.time.now();
    const frame = window.frameCount();

    if (frame != last + 1) {
        start, fpsFrame = .{ time, frame };
    } else if (sk.time.diff(time, start) >= std.time.ns_per_s) {
        fps = frame - fpsFrame;
        start, fpsFrame = .{ time, frame };
        frameTime = sk.app.frameDuration() * 1000;
        // 自身用时直接扣掉窗口 beginPass 的耗时，其余位置的等待仍会保留。
        usedTime = sk.time.ms(window.frameTicks - graphics.beginPassTicks);
    }
    last = frame;

    var labelBuffer: [1000]u8 = undefined;
    var leftBuffer: [1000]u8 = undefined;
    var rightBuffer: [1000]u8 = undefined;
    var columns = Columns{
        .label = .fixed(&labelBuffer),
        .left = .fixed(&leftBuffer),
        .right = .fixed(&rightBuffer),
    };
    const gfxStats = sk.gfx.queryStats();
    const frameStats = gfxStats.prev_frame;
    const totalStats = gfxStats.total;
    // 获取当前持有的资源总量。
    const assetStats = assets.queryTotalStats();
    // 左右列的格式串与参数成对排列，便于对应面板内容。
    // zig fmt: off
    writeFormatLine(&columns, "后端",
        "{s}", .{@tagName(graphics.queryBackend())},
        "帧率 {}", .{fps});
    writeFormatLine(&columns, "帧时",
        "{d:.2} ms", .{frameTime},
        "用时 {d:.2} ms", .{usedTime});
    writeFormatLine(&columns, "窗口",
        "{d:.0}x{d:.0}", .{ window.size.x, window.size.y },
        "逻辑 {d:.0}x{d:.0}", .{ camera.size.x, camera.size.y });
    // 显示触摸控件采用的界面倍率，与按钮相机使用同一计算。
    writeFormatLine(&columns, "显示",
        "界面 {d:.0}%", .{window.dpi() * 100},
        "画面 {d:.0}%", .{window.viewRect.size.x / camera.size.x * 100});
    // 按有效顶点数统计本帧上传的数据量。
    const vertexBytes = assets.frameStats.vertex * @sizeOf(graphics.Vertex);
    writeFormatLine(&columns, "图形",
        "纹理 {}", .{totalStats.images.alive},
        "顶点 {} KB", .{vertexBytes / 1024});
    writeFormatLine(&columns, "绘制",
        "批次 {}", .{frameStats.num_draw},
        "命令 {}", .{batch.commands.items.len});
    writeFormatLine(&columns, "对象",
        "精灵 {}", .{assets.frameStats.vertex},
        "文字 {}", .{assets.frameStats.text});
    writeFormatLine(&columns, "内存",
        "使用 {} KB", .{assetStats.memoryUsed / 1024},
        "最高 {} KB", .{assetStats.memoryPeak / 1024});
    writeFormatLine(&columns, "鼠标",
        "{d:.1}, {d:.1}", .{ window.mouse.raw.x, window.mouse.raw.y },
        "{d:.1}, {d:.1}", .{ window.mouse.pos.x, window.mouse.pos.y });
    writeFormatLine(&columns, "相机",
        "{d:.1}, {d:.1}", .{ camera.main.position.x, camera.main.position.y },
        "缩放 {d:.2}, {d:.2}", .{ camera.main.scale.x, camera.main.scale.y });
    writeFormatLine(&columns, "资源",
        "文件 {}", .{assetStats.file},
        "图片 {}", .{assetStats.image});
    // 字号按字体类型显示，字库容量包含已经缓存的字形。
    const fontStats = text.stats;
    // 字体名最多显示 18 字节，截断时避开 UTF-8 后续字节。
    var nameLen = @min(fontStats.name.len, 18);
    if (nameLen < fontStats.name.len) {
        while (nameLen > 0 and fontStats.name[nameLen] & 0xc0 == 0x80)
            nameLen -= 1;
    }
    writeFormatLine(&columns, "字体", "{s}", .{fontStats.name[0..nameLen]},
        "字号 {d:.1} px", .{fontStats.size});
    writeFormatLine(&columns, "字库",
        "字形 {}", .{fontStats.count},
        "容量 ≈{}", .{fontStats.capacity});
    writeFormatLine(&columns, "音频",
        "音乐 {}", .{assetStats.music},
        "音效 {}", .{assetStats.sound});
    writeFormatLine(&columns, "音量",
        "音乐 {d:.0}%", .{audio.musicVolume.load(.acquire) * 100},
        "音效 {d:.0}%", .{audio.soundVolume.load(.acquire) * 100});
    // zig fmt: on
    for (option.extra) |row| writeRow(&columns, row);
    const labels = labelBuffer[0 .. columns.label.end - 1];
    const left = leftBuffer[0 .. columns.left.end - 1];
    const right = rightBuffer[0 .. columns.right.end - 1];

    camera.push(.window);
    defer camera.pop();

    const textOption = text.Option{
        .color = .rgba(219, 227, 230, 245),
    };
    const padding = Vector2.xy(10, 9);
    const gap = 12;
    const position = option.position;
    const labelSize = text.measure(labels, textOption);
    const panelSize = Vector2.xy(
        camera.state.size.x - position.x * 2,
        labelSize.y + padding.y * 2,
    );
    const labelWidth = labelSize.x;
    const columnWidth = (panelSize.x - padding.x * 2 - labelWidth - gap * 2) / 2;
    batch.drawRect(Rect.init(position, panelSize), .{
        .color = .rgba(18, 23, 28, 140),
    });

    const contentPosition = position.add(padding);
    text.draw(labels, contentPosition, textOption);
    const leftPosition = contentPosition.addX(labelWidth + gap);
    text.draw(left, leftPosition, textOption);
    const rightPosition = leftPosition.addX(columnWidth + gap);
    text.draw(right, rightPosition, textOption);
}

fn writeRow(columns: *Columns, row: Row) void {
    writeLine(&columns.label, row.label);
    writeLine(&columns.left, row.left);
    writeLine(&columns.right, row.right);
}

fn writeFormatLine(
    columns: *Columns,
    label: []const u8,
    comptime leftFormat: []const u8,
    leftArgs: anytype,
    comptime rightFormat: []const u8,
    rightArgs: anytype,
) void {
    var leftBuffer: [80]u8 = undefined;
    var rightBuffer: [80]u8 = undefined;
    const left = zhu.format(&leftBuffer, leftFormat, leftArgs);
    const right = zhu.format(&rightBuffer, rightFormat, rightArgs);
    writeLine(&columns.label, label);
    writeLine(&columns.left, left);
    writeLine(&columns.right, right);
}

fn writeLine(writer: *std.Io.Writer, value: []const u8) void {
    writeAll(writer, value);
    writeAll(writer, "\n");
}

fn writeAll(writer: *std.Io.Writer, value: []const u8) void {
    writer.writeAll(value) catch @panic("debug text too long");
}
