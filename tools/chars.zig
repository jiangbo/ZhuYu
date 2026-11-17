//! 收集原文中的字符，供 BMFont 和 MSDF 的构建配置共用。
const std = @import("std");

const Build = std.Build;
const Dir = std.Io.Dir;
const Utf8View = std.unicode.Utf8View;
const CharSet = std.AutoHashMapUnmanaged(u21, void);

// 读取 TTF/OTF 的 Unicode cmap，不把字体未支持的字符传给生成器。
pub fn readFont(b: *Build, path: []const u8) ![]const u21 {
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
const Allocator = std.mem.Allocator;
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
pub fn read(b: *Build, dep: *Build.Dependency, input: ?[]const u8) ![]const u21 {
    const io = b.graph.io;
    const gpa = b.allocator;
    const cwd = Dir.cwd();
    // 字符集合只在本次提取中使用。
    var chars: CharSet = .empty;
    // 数值和英文可能运行时生成，始终包含可打印 ASCII。
    for (32..127) |code| try chars.put(gpa, @intCast(code), {});
    // 默认包含引擎统计界面的文字，不维护重复字表。
    try readFile(dep.builder, &chars, "src/extend/debug.zig");

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
                    try readFile(b, &chars, filePath);
                }
            }
        } else {
            try readFile(b, &chars, path);
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
fn readFile(b: *Build, chars: *CharSet, path: []const u8) !void {
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
