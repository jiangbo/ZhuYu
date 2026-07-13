const std = @import("std");

const sk = @import("sokol");
const assets = @import("assets.zig");
const audio = @import("audio.zig");
const batch = @import("batch.zig");
const camera = @import("camera.zig");
const graphics = @import("graphics.zig");
const input = @import("input.zig");
const memory = @import("internal/memory.zig");
const text = @import("text.zig");
const window = @import("window.zig");

const Color = graphics.Color;
const Vector2 = @import("math.zig").Vector2;
const Rect = @import("math.zig").Rect;

const basePadding = Vector2.xy(10, 9);

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

// 返回可热重载的 ZON 数据指针。首次调用会从文件读取。
pub fn zon(comptime T: type, comptime path: [:0]const u8) *T {
    const file = ZonFile(T, path);
    if (file.parsed == null and !file.reload()) {
        std.debug.panic("zon load failed: {s}", .{path});
    }
    const result = zonMap.getOrPut(memory.allocator.raw, path) //
        catch memory.oom();
    if (!result.found_existing) {
        result.value_ptr.* = .{
            .path = path,
            .mtime = window.statFileTime(path),
            .reload = file.reload,
            .deinit = file.deinit,
        };
    }

    return &file.parsed.?.value;
}

// 重新加载有变化的 ZON 文件。
pub fn reloadZon() void {
    var iterator = zonMap.valueIterator();
    while (iterator.next()) |entry| {
        const mtime = window.statFileTime(entry.path);
        if (mtime == 0 or mtime == entry.mtime) continue;

        const loaded = entry.reload();
        entry.mtime = mtime;
        if (loaded) std.log.info("zon reloaded: {s}", .{entry.path});
    }
}

// 释放调试热重载保存的 ZON 数据。
pub fn deinit() void {
    var iterator = zonMap.valueIterator();
    while (iterator.next()) |entry| entry.deinit();
    zonMap.deinit(memory.allocator.raw);
}

const ZonEntry = struct {
    path: [:0]const u8,
    mtime: i128,
    reload: *const fn () bool,
    deinit: *const fn () void,
};

var zonMap: std.StringHashMapUnmanaged(ZonEntry) = .empty;

fn ZonFile(comptime T: type, comptime path: [:0]const u8) type {
    return struct {
        var parsed: ?window.Zon(T) = null;

        fn reload() bool {
            const next = window.readZon(T, path, .{}) catch |err| {
                std.log.err("zon reload failed: {s}: {}", .{ path, err });
                return false;
            };

            if (parsed) |*old| old.deinit();
            parsed = next;
            return true;
        }

        fn deinit() void {
            if (parsed) |*old| old.deinit();
        }
    };
}

var last: u64 = 0;
var fps: u64 = 0;
var fpsFrame: u64 = 0;
var start: u64 = 0;
var frameTime: f64 = 0;
var usedTime: f64 = 0;

pub fn draw(rows: []const Row) void {
    const time = sk.time.now();
    const frame = window.frameCount();

    if (frame != last + 1) {
        start, fpsFrame = .{ time, frame };
    } else if (sk.time.diff(time, start) >= std.time.ns_per_s) {
        fps = frame - fpsFrame;
        start, fpsFrame = .{ time, frame };
        frameTime = sk.app.frameDuration() * 1000;
        usedTime = sk.time.ms(window.frameTicks);
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
    writeFormatLine(&columns, "后端", "{s}", .{
        @tagName(graphics.queryBackend()),
    }, "帧率 {}", .{fps});
    writeFormatLine(&columns, "帧时", "{d:.2} ms", .{
        frameTime,
    }, "用时 {d:.2} ms", .{usedTime});
    writeFormatLine(&columns, "窗口", "{d:.0}x{d:.0}", .{
        window.clientSize.x,
        window.clientSize.y,
    }, "逻辑 {d:.0}x{d:.0}", .{ window.size.x, window.size.y });
    writeFormatLine(&columns, "缩放", "屏幕 {d:.0}%", .{
        sk.app.dpiScale() * 100,
    }, "画面 {d:.0}%", .{
        window.viewRect.size.x / window.size.x * 100,
    });
    writeFormatLine(&columns, "图形", "纹理 {}", .{
        totalStats.images.alive,
    }, "顶点 {} KB", .{frameStats.size_update_buffer / 1024});
    const batchUsed: f32 = @floatFromInt(batch.vertices.items.len);
    const batchCap: f32 = @floatFromInt(batch.vertices.capacity);
    writeFormatLine(&columns, "绘制", "批次 {}", .{
        frameStats.num_draw,
    }, "容量 {d:.0}%", .{batchUsed / batchCap * 100});
    writeFormatLine(&columns, "对象", "精灵 {}", .{
        batch.vertices.items.len,
    }, "文字 {}", .{graphics.stats.text});
    writeFormatLine(&columns, "内存", "使用 {} KB", .{
        memory.counter.used / 1024,
    }, "最高 {} KB", .{memory.counter.max / 1024});
    writeFormatLine(&columns, "鼠标", "{d:.1}, {d:.1}", .{
        input.mouse.raw.x,
        input.mouse.raw.y,
    }, "{d:.1}, {d:.1}", .{ window.mouse.x, window.mouse.y });
    writeFormatLine(&columns, "相机", "{d:.1}, {d:.1}", .{
        camera.main.position.x,
        camera.main.position.y,
    }, "{d:.2}, {d:.2}", .{ camera.main.scale.x, camera.main.scale.y });
    // 获取当前已加载的资源统计数据
    const assetStats = assets.queryStats();
    writeFormatLine(&columns, "资源", "文件 {}", .{assetStats.file}, //
        "图片 {}", .{assetStats.image});
    writeFormatLine(&columns, "音频", "音乐 {}", .{assetStats.music}, //
        "音效 {}", .{assetStats.sound});
    writeFormatLine(&columns, "音量", "音乐 {d:.0}%", .{
        audio.musicVolume.load(.acquire) * 100,
    }, "音效 {d:.0}%", .{audio.soundVolume.load(.acquire) * 100});
    for (rows) |row| writeRow(&columns, row);
    const labels = labelBuffer[0 .. columns.label.end - 1];
    const left = leftBuffer[0 .. columns.left.end - 1];
    const right = rightBuffer[0 .. columns.right.end - 1];

    // 调试面板固定在窗口坐标，绘制后还原当前相机。
    camera.push(.window);
    defer camera.pop();

    const baseOption = text.Option{};
    const labelSize = text.measure(labels, baseOption);
    const gap = text.measure("    ", baseOption).x;
    const scale = debugTextScale(labelSize.y);
    const padding = basePadding.scale(scale.x);
    const position = Vector2.xy(10, 10).scale(scale.x);
    const panelWidth = window.size.x * 0.70;
    const contentWidth = (panelWidth - padding.x * 2) / scale.x;
    const valueWidth = (contentWidth - labelSize.x - gap * 2) / 2;
    const textOption = text.Option{
        .color = .rgba(0.86, 0.89, 0.90, 0.96),
        .scale = scale,
    };
    const panelSize = Vector2.xy(
        panelWidth,
        labelSize.y * scale.y + padding.y * 2,
    );
    const panel = Rect.init(position, panelSize);

    batch.drawRect(panel, .{ .color = .rgba(0.07, 0.09, 0.11, 0.74) });

    const contentPosition = position.add(padding);
    text.draw(labels, contentPosition, textOption);
    const leftPosition = contentPosition.addX((labelSize.x + gap) * scale.x);
    text.draw(left, leftPosition, textOption);
    const rightPosition = leftPosition.addX((valueWidth + gap) * scale.x);
    text.draw(right, rightPosition, textOption);
}

fn writeRow(columns: *Columns, row: Row) void {
    writeLine(&columns.label, row.label);
    writeLine(&columns.left, row.left);
    writeLine(&columns.right, row.right);
}

fn debugTextScale(contentHeight: f32) Vector2 {
    const baseHeight = contentHeight + basePadding.y * 2;
    const maxHeight = window.size.y * 0.75;

    const rawScale = maxHeight / baseHeight;

    // 按半档缩放，避免调试面板盖住主要画面。
    const stepped = @round(std.math.clamp(rawScale, 0.5, 1.5) * 2) / 2;
    return .square(stepped);
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
    const left = text.format(&leftBuffer, leftFormat, leftArgs);
    const right = text.format(&rightBuffer, rightFormat, rightArgs);
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
