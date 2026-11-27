const std = @import("std");
const core = @import("core.zig");
const image = @import("zhu").image;

const Build = std.Build;
const Dependency = Build.Dependency;

pub const Pngquant = core.Pngquant;

pub const Item = struct {
    src: []const u8,
    dst: []const u8,
    include: []const []const u8 = &.{}, // 相对于 src 目录，为空时包含全部。
    exclude: []const []const u8 = &.{}, // 相对于 src 目录；目录以 / 结尾。
    premul: bool = false, // 是否预乘 Alpha（仅支持 PNG）。
    pngquant: ?Pngquant = null, // 开启有损索引色压缩，系统需安装 pngquant。
};

pub const Options = struct { items: []const Item, name: []const u8 = "copy" };

// PNG 按配置量化和预乘，PNG 和 ICO 尝试 oxipng 优化，其他文件原样拷贝。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) void {
    const copy = b.addUpdateSourceFiles();
    var tool: ?*Build.Step.Compile = null;
    for (options.items) |item| {
        if (item.pngquant) |q| q.validate() catch |err| {
            std.debug.panic("copy {s} -> {s}: pngquant: {s}", .{
                item.src, item.dst, @errorName(err),
            });
        };
        var dir = b.root.openDir(
            b.graph.io,
            item.src,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.NotDir => {
                std.debug.assert(item.include.len == 0 and item.exclude.len == 0);
                addFile(b, dep, copy, &tool, item);
                continue;
            },
            else => std.debug.panic("copy failed to open {s}: {}", .{ item.src, err }),
        };
        defer dir.close(b.graph.io);

        const rules = core.PathRules.init(item.include, item.exclude);
        var walker = rules.walk(dir, b.allocator) catch @panic("out of memory");
        defer walker.deinit(b.graph.io);
        while (walker.next(b.graph.io) catch |err|
            std.debug.panic("copy failed to walk {s}: {}", .{ item.src, err })) |entry|
        {
            const srcPath = b.pathJoin(&.{ item.src, entry.path });
            const dstPath = b.pathJoin(&.{ item.dst, entry.path });
            const isPng = std.ascii.endsWithIgnoreCase(entry.path, ".png");
            addFile(b, dep, copy, &tool, .{
                .src = srcPath,
                .dst = dstPath,
                .premul = item.premul and isPng,
                .pngquant = if (isPng) item.pngquant else null,
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
    if ((item.premul or item.pngquant != null) and !png)
        std.debug.panic("PNG options require PNG paths: {s} -> {s}", .{ src, dst });
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
        exe.root_module.addImport("zhu", core.createZhuModule(b, dep));
        tool.* = exe;
    }
    const run = b.addRunArtifact(tool.*.?);
    run.addFileArg(b.path(src));
    const out = run.addOutputFileArg(std.fs.path.basename(dst));
    if (item.premul) run.addArg("--premul");
    if (item.pngquant) |q| {
        const config = b.fmt("{f}", .{std.zon.fmt(q, .{ .whitespace = false })});
        run.addArgs(&.{ "--pngquant", config });
    }
    copy.addCopyFileToSource(out, dst);
}

// 独立运行入口：量化或预乘 PNG，优化 PNG 或 ICO。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.InvalidArgs;
    var premul = false;
    var pngquant: ?Pngquant = null;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--premul")) {
            premul = true;
        } else if (std.mem.eql(u8, arg, "--pngquant")) {
            index += 1;
            if (index == args.len or pngquant != null) return error.InvalidArgs;
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            const q = std.zon.parse.fromSlice(Pngquant, .{
                .gpa = gpa,
                .arena = gpa,
                .source = args[index],
                .diagnostics = &diagnostics,
            }) catch |err| {
                if (err == error.ParseZon) diagnostics.log("--pngquant");
                return err;
            };
            try q.validate();
            pngquant = q;
        } else return error.InvalidArgs;
    }

    const ico = std.ascii.endsWithIgnoreCase(args[1], ".ico");
    if ((premul or pngquant != null) and ico) return error.InvalidArgs;
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
        if (pngquant) |q| {
            bytes = try core.quantizePng(io, gpa, directory, source, q);
            if (premul) try core.premultiplyPalette(bytes);
        } else if (premul) {
            const decoded = try image.load(gpa, source);
            core.premultiply(decoded.data);
            bytes = try core.encodePng(gpa, .{
                .width = @intCast(decoded.width),
                .height = @intCast(decoded.height),
                .pixels = decoded.data,
            }, false);
        }
        if (try core.optimizePng(io, gpa, directory, bytes)) |optimized| {
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
            bytes = try core.encodePng(gpa, .{
                .width = @intCast(decoded.width),
                .height = @intCast(decoded.height),
                .pixels = decoded.data,
            }, false);
        }
        if (useOxipng) {
            if (try core.optimizePng(io, gpa, dir, bytes)) |optimized| {
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
