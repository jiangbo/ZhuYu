const std = @import("std");
const zigimg = @import("zigimg");

const Build = std.Build;
const Dependency = Build.Dependency;

pub const Item = struct {
    src: []const u8,
    dst: []const u8,
    premul: bool = false, // 是否预乘 Alpha（仅支持 PNG）。
};

// 拷贝散图或目录到目标路径；单文件开启 premul 仅支持 PNG，目录内非 PNG 原样拷贝。
pub fn addStep(
    b: *Build,
    dep: *Dependency,
    items: []const Item,
) *Build.Step {
    const copy = b.addUpdateSourceFiles();
    var tool: ?*Build.Step.Compile = null;
    for (items) |item| {
        var dir = b.build_root.handle.openDir(
            b.graph.io,
            item.src,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.NotDir => {
                addFile(b, dep, copy, &tool, item.src, item.dst, item.premul);
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
            addFile(b, dep, copy, &tool, srcPath, dstPath, item.premul and isPng);
        }
    }
    return &copy.step;
}

fn addFile(
    b: *Build,
    dep: *Dependency,
    copy: *Build.Step.UpdateSourceFiles,
    tool: *?*Build.Step.Compile,
    src: []const u8,
    dst: []const u8,
    premul: bool,
) void {
    if (!premul) {
        copy.addCopyFileToSource(b.path(src), dst);
        return;
    }
    if (!std.ascii.endsWithIgnoreCase(src, ".png") or
        !std.ascii.endsWithIgnoreCase(dst, ".png"))
    {
        std.debug.panic("premul only supports PNG: {s} -> {s}", .{ src, dst });
    }
    if (tool.* == null) {
        const zigimgDep = dep.builder.lazyDependency("zigimg", .{
            .target = b.graph.host,
            .optimize = .safe,
        }) orelse return;
        const exe = b.addExecutable(.{
            .name = "zhuyu-copy",
            .root_module = b.createModule(.{
                .root_source_file = dep.path("tools/copy.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        exe.root_module.addImport("zigimg", zigimgDep.module("zigimg"));
        tool.* = exe;
    }
    const run = b.addRunArtifact(tool.*.?);
    run.addFileArg(b.path(src));
    const out = run.addOutputFileArg(std.fs.path.basename(dst));
    copy.addCopyFileToSource(out, dst);
}

// 独立运行入口：读取单个 PNG，按 Alpha 预乘后写到输出路径。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.InvalidArgs;

    const decoded = try decodePng(io, gpa, args[1]);
    premultiply(decoded.pixels);
    const bytes = try encodePng(gpa, decoded);
    if (std.fs.path.dirname(args[2])) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = bytes });
}

pub const PngImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

// 读取 PNG 并转换为统一的 RGBA 像素。
pub fn decodePng(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) !PngImage {
    var buffer: [64 * 1024]u8 = undefined;
    var image = try zigimg.Image.Managed.fromFilePath(gpa, io, path, &buffer);
    defer image.deinit();
    try image.convert(.rgba32);

    return .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .pixels = try gpa.dupe(u8, image.rawBytes()),
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

// 将 RGBA 像素编码为 PNG，尺寸和像素共用一个图片描述。
pub fn encodePng(gpa: std.mem.Allocator, source: PngImage) ![]u8 {
    const pixels = source.pixels;
    const width = source.width;
    const height = source.height;
    if (pixels.len != @as(usize, width) * height * 4) {
        return error.InvalidPixels;
    }

    const storage = try zigimg.color.PixelStorage.initRawPixels(pixels, .rgba32);
    const image = zigimg.Image{
        .width = width,
        .height = height,
        .pixels = storage,
    };
    const buffer = try gpa.alloc(u8, pixels.len * 2 + 1024);
    defer gpa.free(buffer);
    const encoded = try image.writeToMemory(gpa, buffer, .{ .png = .{
        .filter_choice = .{ .specified = .none },
    } });
    return gpa.dupe(u8, encoded);
}
