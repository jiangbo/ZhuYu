const std = @import("std");
const image = @import("zhu").image;

const Build = std.Build;
const Dependency = Build.Dependency;

// 工具在缓存中共用字体类型和解码器，不修改引擎源码。
pub fn createZhuModule(b: *Build, dep: *Dependency) *Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(dep.path("src"), "src", .{});
    const entry = files.add("src/tools.zig",
        \\pub const text = @import("text.zig").static;
        \\pub const image = @import("internal/image.zig");
    );
    const config = b.addOptions();
    config.addOption(enum { static, system, custom }, "font", .static);
    const module = b.createModule(.{
        .root_source_file = entry,
        .target = b.graph.host,
        .optimize = .safe,
    });
    module.addOptions("options", config);
    return module;
}

pub const Item = struct {
    src: []const u8,
    dst: []const u8,
    premul: bool = false, // 是否预乘 Alpha（仅支持 PNG）。
};

pub const Options = struct { items: []const Item, name: []const u8 = "copy" };

// PNG 和 ICO 自动尝试 oxipng 优化，PNG 按配置预乘，其他文件原样拷贝。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) void {
    const copy = b.addUpdateSourceFiles();
    var tool: ?*Build.Step.Compile = null;
    for (options.items) |item| {
        var dir = b.root.openDir(
            b.graph.io,
            item.src,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.NotDir => {
                addFile(b, dep, copy, &tool, item);
                continue;
            },
            else => std.debug.panic("copy failed to open {s}: {}", .{ item.src, err }),
        };
        defer dir.close(b.graph.io);

        var walker = dir.walk(b.allocator) catch @panic("out of memory");
        defer walker.deinit();
        while (walker.next(b.graph.io) catch |err|
            std.debug.panic("copy failed to walk {s}: {}", .{ item.src, err })) |entry|
        {
            if (entry.kind != .file) continue;
            const srcPath = b.pathJoin(&.{ item.src, entry.path });
            const dstPath = b.pathJoin(&.{ item.dst, entry.path });
            const isPng = std.ascii.endsWithIgnoreCase(entry.path, ".png");
            addFile(b, dep, copy, &tool, .{
                .src = srcPath,
                .dst = dstPath,
                .premul = item.premul and isPng,
            });
        }
    }
    b.step(options.name, "Copy standalone assets").dependOn(&copy.step);
}

fn addFile(
    b: *Build,
    dep: *Dependency,
    copy: *Build.Step.UpdateSourceFiles,
    tool: *?*Build.Step.Compile,
    item: Item,
) void {
    const src = item.src;
    const dst = item.dst;
    const png = std.ascii.endsWithIgnoreCase(src, ".png") and
        std.ascii.endsWithIgnoreCase(dst, ".png");
    const ico = std.ascii.endsWithIgnoreCase(src, ".ico") and
        std.ascii.endsWithIgnoreCase(dst, ".ico");
    if (item.premul and !png)
        std.debug.panic("premul requires PNG paths: {s} -> {s}", .{ src, dst });
    if (!png and !ico) {
        copy.addCopyFileToSource(b.path(src), dst);
        return;
    }
    if (tool.* == null) {
        const exe = b.addExecutable(.{
            .name = "zhuyu-copy",
            .root_module = b.createModule(.{
                .root_source_file = dep.path("tools/copy.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        exe.root_module.addImport("zhu", createZhuModule(b, dep));
        tool.* = exe;
    }
    const run = b.addRunArtifact(tool.*.?);
    run.addFileArg(b.path(src));
    const out = run.addOutputFileArg(std.fs.path.basename(dst));
    if (item.premul) run.addArg("--premul");
    copy.addCopyFileToSource(out, dst);
}

// 独立运行入口：预乘 PNG，优化 PNG 或 ICO。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.InvalidArgs;
    var premul = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--premul")) {
            premul = true;
        } else return error.InvalidArgs;
    }

    const ico = std.ascii.endsWithIgnoreCase(args[1], ".ico");
    if (premul and ico) return error.InvalidArgs;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    const directory = std.fs.path.dirname(args[2]) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, directory);
    var bytes = source;
    if (ico) {
        bytes = try packIco(io, gpa, directory, source);
        std.log.info("ICO {s}: {} -> {} bytes, saved {} bytes", .{
            args[2], source.len, bytes.len, source.len -| bytes.len,
        });
    } else {
        if (premul) {
            const decoded = try image.load(gpa, source);
            premultiply(decoded.data);
            bytes = try encodePng(gpa, .{
                .width = @intCast(decoded.width),
                .height = @intCast(decoded.height),
                .pixels = decoded.data,
            }, false);
        }
        if (try optimizePng(io, gpa, directory, bytes)) |optimized| {
            std.log.info("oxipng {s}: {} -> {} bytes, saved {} bytes", .{
                args[2], bytes.len, optimized.len, bytes.len -| optimized.len,
            });
            bytes = optimized;
        } else std.log.info("oxipng not found, skipping PNG optimization", .{});
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = bytes });
    std.log.info("copied {s} {s}: {} bytes", .{
        if (ico) "ICO" else "PNG", args[2], bytes.len,
    });
}

const Allocator = std.mem.Allocator;
// 保留 ICO 的全部图层；DIB 复用引擎解码器，PNG 保留现有压缩数据。
fn packIco(io: std.Io, gpa: Allocator, dir: []const u8, src: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(src);
    if (try reader.takeInt(u16, .little) != 0 or
        try reader.takeInt(u16, .little) != 1) return error.InvalidIcon;
    const count = try reader.takeInt(u16, .little);
    if (count == 0) return error.InvalidIcon;
    const header = try reader.take(@as(usize, count) * 16);
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(gpa, src[0 .. 6 + header.len]);
    var useOxipng = true;
    for (0..count) |i| {
        const entry = header[i * 16 ..][0..16];
        const size = std.mem.readInt(u32, entry[8..12], .little);
        const offset = std.mem.readInt(u32, entry[12..16], .little);
        if (size == 0 or offset > src.len or size > src.len - offset)
            return error.InvalidIcon;
        var bytes = src[offset..][0..size];
        if (!std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
            // 单图层 ICO 让现有解码器读取该 DIB，而不是选择最大图层。
            const single = try gpa.alloc(u8, 22 + bytes.len);
            @memcpy(single[0..6], src[0..6]);
            std.mem.writeInt(u16, single[4..6], 1, .little);
            @memcpy(single[6..22], entry);
            std.mem.writeInt(u32, single[18..22], 22, .little);
            @memcpy(single[22..], bytes);
            const decoded = try image.loadIcon(gpa, single);
            bytes = try encodePng(gpa, .{
                .width = @intCast(decoded.width),
                .height = @intCast(decoded.height),
                .pixels = decoded.data,
            }, false);
        }
        if (useOxipng) {
            if (try optimizePng(io, gpa, dir, bytes)) |optimized| {
                std.log.info("oxipng ICO layer {}: {} -> {} bytes", .{
                    i, bytes.len, optimized.len,
                });
                bytes = optimized;
            } else {
                std.log.info("oxipng not found, skipping PNG optimization", .{});
                useOxipng = false;
            }
        }
        const start: u32 = @intCast(output.items.len);
        try output.appendSlice(gpa, bytes);
        const target = output.items[6 + i * 16 ..][0..16];
        std.mem.writeInt(u32, target[8..12], @intCast(bytes.len), .little);
        std.mem.writeInt(u32, target[12..16], start, .little);
    }
    return output.toOwnedSlice(gpa);
}

pub const PngImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

// 读取 PNG 并转换为统一的 RGBA 像素。
pub fn decodePng(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !PngImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const decoded = try image.load(gpa, bytes);
    return .{
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .pixels = decoded.data,
    };
}

// 按 Alpha 通道预乘 RGBA 像素，消除透明边缘缩放黑边。
pub fn premultiply(pixels: []u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const alpha: u16 = pixels[i + 3];
        if (alpha == 0) {
            @memset(pixels[i..][0..3], 0);
        } else if (alpha < 255) {
            pixels[i + 0] = @intCast((@as(u16, pixels[i + 0]) * alpha + 127) / 255);
            pixels[i + 1] = @intCast((@as(u16, pixels[i + 1]) * alpha + 127) / 255);
            pixels[i + 2] = @intCast((@as(u16, pixels[i + 2]) * alpha + 127) / 255);
        }
    }
}

// 写出 RGBA PNG；二值白色字体使用两色 1-bit 索引。
pub fn encodePng(gpa: std.mem.Allocator, source: PngImage, bitmap: bool) ![]u8 {
    const width: usize = @intCast(source.width);
    const height: usize = @intCast(source.height);
    if (width == 0 or height == 0 or source.pixels.len != width * height * 4)
        return error.InvalidPixels;
    const rowSize = if (bitmap) (width + 7) / 8 else width * 4;
    const rows = try gpa.alloc(u8, (rowSize + 1) * height);
    defer gpa.free(rows);
    @memset(rows, 0);
    for (0..height) |y| {
        const row = rows[y * (rowSize + 1) + 1 ..][0..rowSize];
        const pixels = source.pixels[y * width * 4 ..][0 .. width * 4];
        if (bitmap) {
            for (0..width) |x| {
                const pixel = pixels[x * 4 ..][0..4];
                const alpha = pixel[3];
                if ((alpha != 0 and alpha != 255) or
                    pixel[0] != alpha or pixel[1] != alpha or pixel[2] != alpha)
                    return error.InvalidBitmap;
                const shift: u3 = @intCast(7 - x % 8);
                row[x / 8] |= @as(u8, alpha / 255) << shift;
            }
        } else {
            @memcpy(row, pixels);
        }
    }

    var compressed = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer compressed.deinit();
    const buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(buffer);
    var compressor = try std.compress.flate.Compress.init(
        &compressed.writer,
        buffer,
        .zlib,
        .default,
    );
    try compressor.writer.writeAll(rows);
    try compressor.finish();

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(height), .big);
    header[8..13].* = .{ if (bitmap) 1 else 8, if (bitmap) 3 else 6, 0, 0, 0 };
    try appendChunk(&result, gpa, "IHDR", &header);
    if (bitmap) {
        try appendChunk(&result, gpa, "PLTE", &.{ 0, 0, 0, 255, 255, 255 });
        try appendChunk(&result, gpa, "tRNS", &.{0});
    }
    try appendChunk(&result, gpa, "IDAT", compressed.written());
    try appendChunk(&result, gpa, "IEND", &.{});
    return result.toOwnedSlice(gpa);
}

fn appendChunk(
    result: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    kind: []const u8,
    data: []const u8,
) !void {
    if (kind.len != 4) return error.InvalidChunk;

    var lenBytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenBytes, @intCast(data.len), .big);
    try result.appendSlice(gpa, &lenBytes);
    try result.appendSlice(gpa, kind);
    try result.appendSlice(gpa, data);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);

    var crcBytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcBytes, crc.final(), .big);
    try result.appendSlice(gpa, &crcBytes);
}
// 缺少系统工具时跳过；已安装工具执行失败则显示错误。
pub fn optimizePng(
    io: std.Io,
    gpa: std.mem.Allocator,
    directory: []const u8,
    bytes: []const u8,
) !?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(gpa, &.{ directory, ".oxipng-input.png" });
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
    defer cwd.deleteFile(io, path) catch {};
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "oxipng", "-o", "4", "--strip", "safe", "--stdout", path },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (!result.term.success()) {
        std.log.err("oxipng {f}: {s}", .{ result.term, result.stderr });
        return error.OxipngFailed;
    }
    return result.stdout;
}
