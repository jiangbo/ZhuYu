//! 收集原文中的字符，供 BMFont 和 MSDF 的构建配置共用。
const std = @import("std");
const Build = std.Build;
const Dir = std.Io.Dir;
const Utf8View = std.unicode.Utf8View;
const CharSet = std.AutoHashMapUnmanaged(u21, void);

// 构建配置直接读取文件或递归扫描目录，不另建收集程序或命令。
pub fn read(b: *Build, input: ?[]const u8) ![]const u21 {
    const io = b.graph.io;
    const gpa = b.allocator;
    const cwd = Dir.cwd();
    // 字符集合只在本次提取中使用。
    var chars: CharSet = .empty;
    // 数值和英文可能运行时生成，始终包含可打印 ASCII。
    for (32..127) |code| try chars.put(gpa, @intCast(code), {});

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
