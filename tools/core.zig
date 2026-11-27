//! 资源工具共用的路径筛选、图像处理、宿主模块和字符收集。
const std = @import("std");

const Allocator = std.mem.Allocator;
const Build = std.Build;
const Dir = std.Io.Dir;
const Dependency = Build.Dependency;
const Utf8View = std.unicode.Utf8View;
const CharSet = std.AutoHashMapUnmanaged(u21, void);

pub const PathRules = struct {
    include: []const []const u8,
    exclude: []const []const u8,

    pub fn init(include: []const []const u8, exclude: []const []const u8) PathRules {
        return .{ .include = include, .exclude = exclude };
    }

    pub fn walk(rules: PathRules, dir: Dir, gpa: Allocator) !FileWalker {
        return .{ .walker = try dir.walkSelectively(gpa), .rules = rules };
    }

    // 规则相对于输入根目录。文件精确匹配，尾随 / 表示整棵子树。
    fn accepts(rules: PathRules, path: []const u8, directory: bool) bool {
        for (rules.exclude) |rule| {
            if (matchesPath(rule, path, directory)) return false;
        }
        if (rules.include.len == 0) return true;
        for (rules.include) |rule| {
            if (matchesPath(rule, path, directory)) return true;
            if (directory and isBelow(rule, path, '/')) return true;
        }
        return false;
    }
};

pub const FileWalker = struct {
    walker: Dir.SelectiveWalker,
    rules: PathRules,

    // 路径和目录句柄有效至下次 next 或 deinit。
    pub fn next(self: *FileWalker, io: std.Io) !?Dir.Walker.Entry {
        while (try self.walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (self.rules.accepts(entry.path, true))
                        try self.walker.enter(io, entry);
                },
                .file => if (self.rules.accepts(entry.path, false)) return entry,
                else => {},
            }
        }
        return null;
    }

    pub fn deinit(self: *FileWalker, io: std.Io) void {
        while (self.walker.stack.items.len > 1) self.walker.leave(io);
        self.walker.deinit();
    }
};

fn matchesPath(rule: []const u8, path: []const u8, directory: bool) bool {
    if (!std.mem.endsWith(u8, rule, "/")) return !directory and samePath(rule, path);
    const name = rule[0 .. rule.len - 1];
    return (directory and samePath(name, path)) or isBelow(path, name, std.fs.path.sep);
}

fn isBelow(path: []const u8, parent: []const u8, separator: u8) bool {
    return path.len > parent.len and path[parent.len] == separator and
        samePath(path[0..parent.len], parent);
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (std.fs.path.sep == '/') return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (resourceSeparator(x) != resourceSeparator(y)) return false;
    }
    return true;
}

fn resourceSeparator(byte: u8) u8 {
    return if (byte == std.fs.path.sep) '/' else byte;
}

pub fn resourcePath(gpa: Allocator, path: []const u8) ![]const u8 {
    const result = try gpa.dupe(u8, path);
    std.mem.replaceScalar(u8, result, std.fs.path.sep, '/');
    return result;
}

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

pub const PngImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

// 读取 PNG 并转换为统一的 RGBA 像素。
pub fn decodePng(io: std.Io, gpa: Allocator, dir: Dir, path: []const u8) !PngImage {
    const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const decoded = try @import("zhu").image.load(gpa, bytes);
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

// 读取 TTF/OTF 的 Unicode cmap，不把字体未支持的字符传给生成器。
pub fn readFontChars(b: *Build, path: []const u8) ![]const u21 {
    b.dependOnFileContents(b.path(path));
    const absolute = try b.root.joinString(b.allocator, path);
    const bytes = try Dir.cwd().readFileAlloc(
        b.graph.io,
        absolute,
        b.allocator,
        .unlimited,
    );
    const tableCount = try fontInt(u16, bytes, 4);
    for (0..tableCount) |i| {
        const record = 12 + i * 16;
        if (try fontInt(u32, bytes, record) != 0x636d6170) continue;
        const offset = try fontInt(u32, bytes, record + 8);
        const length = try fontInt(u32, bytes, record + 12);
        if (offset > bytes.len or length > bytes.len - offset)
            return error.InvalidFont;
        return readCmap(b.allocator, bytes[offset..][0..length]);
    }
    return error.MissingFontCmap;
}

// 优先完整 Unicode 表（格式 12），否则使用 BMP 表（格式 4）。
fn readCmap(gpa: std.mem.Allocator, bytes: []const u8) ![]const u21 {
    const count = try fontInt(u16, bytes, 2);
    var selected: ?usize = null;
    var format: u16 = 0;
    for (0..count) |i| {
        const record = 4 + i * 8;
        const platform = try fontInt(u16, bytes, record);
        const encoding = try fontInt(u16, bytes, record + 2);
        if (platform != 0 and
            !(platform == 3 and (encoding == 1 or encoding == 10))) continue;
        const offset = try fontInt(u32, bytes, record + 4);
        const candidate = try fontInt(u16, bytes, offset);
        if (candidate != 4 and candidate != 12) continue;
        if (candidate <= format) continue;
        selected = offset;
        format = candidate;
    }
    const offset = selected orelse return error.UnsupportedFontCmap;
    const length = if (format == 12)
        try fontInt(u32, bytes, offset + 4)
    else
        try fontInt(u16, bytes, offset + 2);
    if (length > bytes.len - offset) return error.InvalidFont;
    const table = bytes[offset..][0..length];
    var codes: std.ArrayList(u21) = .empty;
    if (format == 12) {
        const groups = try fontInt(u32, table, 12);
        for (0..groups) |i| {
            const record = 16 + i * 12;
            const first = try fontInt(u32, table, record);
            const last = try fontInt(u32, table, record + 4);
            const glyph = try fontInt(u32, table, record + 8);
            if (first > last or last > 0x10ffff) return error.InvalidFont;
            for (first..@as(usize, last) + 1) |code| {
                if (glyph == 0 and code == first) continue;
                try appendCode(gpa, &codes, code);
            }
        }
    } else {
        const segments = (try fontInt(u16, table, 6)) / 2;
        const starts = 16 + @as(usize, segments) * 2;
        const deltas = starts + segments * 2;
        const ranges = deltas + segments * 2;
        for (0..segments) |i| {
            const first = try fontInt(u16, table, starts + i * 2);
            const last = try fontInt(u16, table, 14 + i * 2);
            const delta = try fontInt(u16, table, deltas + i * 2);
            const range = try fontInt(u16, table, ranges + i * 2);
            if (first > last) return error.InvalidFont;
            for (first..@as(usize, last) + 1) |code| {
                var glyph: u16 = @intCast(code);
                if (range != 0) {
                    const address = ranges + i * 2 + range + (code - first) * 2;
                    glyph = try fontInt(u16, table, address);
                    if (glyph == 0) continue;
                }
                glyph +%= delta;
                if (glyph != 0) try appendCode(gpa, &codes, code);
            }
        }
    }
    return codes.toOwnedSlice(gpa);
}

// 控制字符、代理码点和 BOM 不生成字形，与文本字表的规则一致。
fn appendCode(gpa: Allocator, codes: *std.ArrayList(u21), code: usize) !void {
    if (code < 32 or code == 127 or code == 0xfeff or
        (code >= 0xd800 and code <= 0xdfff)) return;
    try codes.append(gpa, @intCast(code));
}

fn fontInt(comptime T: type, bytes: []const u8, offset: usize) !T {
    if (offset > bytes.len or @sizeOf(T) > bytes.len - offset)
        return error.InvalidFont;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

// 构建配置直接读取文件或递归扫描目录，不另建收集程序或命令。
pub fn collectChars(b: *Build, dep: *Dependency, input: ?[]const u8) ![]const u21 {
    const io = b.graph.io;
    const gpa = b.allocator;
    const cwd = Dir.cwd();
    // 字符集合只在本次提取中使用。
    var chars: CharSet = .empty;
    // 数值和英文可能运行时生成，始终包含可打印 ASCII。
    for (32..127) |code| try chars.put(gpa, @intCast(code), {});
    // 默认包含引擎统计界面的文字，不维护重复字表。
    try collectFileChars(dep.builder, &chars, "src/extend/debug.zig");

    if (input) |path| {
        const absolute = try b.root.joinString(gpa, path);
        const stat = try cwd.statFile(io, absolute, .{});
        if (stat.kind == .directory) {
            b.dependOnDirectoryContents(b.path(path));
            var dir = try cwd.openDir(io, absolute, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                const filePath = try std.fs.path.join(gpa, &.{ path, entry.path });
                if (entry.kind == .directory) {
                    b.dependOnDirectoryContents(b.path(filePath));
                } else if (entry.kind == .file) {
                    try collectFileChars(b, &chars, filePath);
                }
            }
        } else {
            try collectFileChars(b, &chars, path);
        }
    }

    // 字符去重后按 Unicode 编号排序，使输出稳定。
    const codes = try gpa.alloc(u21, chars.count());
    var iterator = chars.keyIterator();
    for (codes) |*code| code.* = iterator.next().?.*;
    std.mem.sort(u21, codes, {}, std.sort.asc(u21));

    return codes;
}

// 按内容识别 UTF-8 文本，跳过二进制文件，不依赖文件后缀。
fn collectFileChars(b: *Build, chars: *CharSet, path: []const u8) !void {
    const absolute = try b.root.joinString(b.allocator, path);
    b.dependOnFileContents(b.path(path));
    const bytes = try Dir.cwd().readFileAlloc(
        b.graph.io,
        absolute,
        b.allocator,
        .unlimited,
    );
    const view = Utf8View.init(bytes) catch return;
    for (bytes) |byte| {
        if (byte == 127 or (byte < 32 and
            byte != '\t' and byte != '\n' and byte != '\r')) return;
    }
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |code| {
        // 换行、制表符和 BOM 不生成字形，普通空格与全角空格保留。
        if (code < 32 or code == 127 or code == 0xfeff) continue;
        try chars.put(b.allocator, code, {});
    }
}
