//! 收集原文中的字符，供 BMFont 和 MSDF 的构建配置共用。
const std = @import("std");
const Build = std.Build;
const Dir = std.Io.Dir;
const Utf8View = std.unicode.Utf8View;

// 两种字表使用相同的字符集合，仅输出格式不同。
pub const Files = struct {
    bmfont: Build.LazyPath,
    msdf: Build.LazyPath,
};

const Collect = struct {
    build: *Build,
    chars: std.AutoHashMapUnmanaged(u21, void) = .empty,

    // 按内容识别 UTF-8 文本，跳过二进制文件，不依赖文件后缀。
    fn readFile(self: *Collect, path: []const u8) !void {
        const b = self.build;
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
            try self.chars.put(b.allocator, code, {});
        }
    }
};

// 构建配置直接读取文件或递归扫描目录，不另建收集程序或命令。
pub fn read(b: *Build, input: []const u8) !Files {
    const io = b.graph.io;
    const gpa = b.allocator;
    const cwd = Dir.cwd();
    const absolute = try b.root.joinString(gpa, input);
    var collect = Collect{ .build = b };
    // 数值和英文可能运行时生成，始终包含可打印 ASCII。
    for (32..127) |code| try collect.chars.put(gpa, @intCast(code), {});

    const stat = try cwd.statFile(io, absolute, .{});
    if (stat.kind == .directory) {
        b.dependOnDirectoryContents(b.path(input));
        var dir = try cwd.openDir(io, absolute, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const path = try std.fs.path.join(gpa, &.{ input, entry.path });
            if (entry.kind == .directory) {
                b.dependOnDirectoryContents(b.path(path));
            } else if (entry.kind == .file) {
                try collect.readFile(path);
            }
        }
    } else {
        try collect.readFile(input);
    }

    // 字符去重后按 Unicode 编号排序，使输出稳定。
    const codes = try gpa.alloc(u21, collect.chars.count());
    var iterator = collect.chars.keyIterator();
    for (codes) |*code| code.* = iterator.next().?.*;
    std.mem.sort(u21, codes, {}, std.sort.asc(u21));

    var content: std.ArrayList(u8) = .empty;
    for (codes) |code| {
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(code, &buffer);
        try content.appendSlice(gpa, buffer[0..len]);
    }
    // BMFont 用 BOM 识别 UTF-8，MSDF 用带引号及转义的字符串表示字符集。
    const bmfont = try std.mem.concat(gpa, u8, &.{ "\xef\xbb\xbf", content.items });
    const msdf = try std.json.Stringify.valueAlloc(gpa, content.items, .{});
    const files = b.addWriteFiles();
    return .{
        .bmfont = files.add("bmfont.txt", bmfont),
        .msdf = files.add("msdf.txt", msdf),
    };
}
