const std = @import("std");

// 路径仅供打包时读取和计算哈希，偏移指向资源包内的文件内容。
const Entry = struct {
    path: [:0]const u8,
    hash: u32, // 收集文件时计算并检查，写索引时直接使用。
    offset: u32 = 0,
    size: u32 = 0,

    // 固定文件顺序，让相同输入生成相同的资源包。
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

// 参数依次为资源目录、输出资源包。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const cwd = std.Io.Dir.cwd();
    var assets = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer assets.close(io);
    var walker = try assets.walk(allocator);
    defer walker.deinit();

    var entries: std.ArrayList(Entry) = .empty;
    // 写入产物前检查路径哈希，发生冲突时指出两个文件。
    var pathsByHash: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    while (try walker.next(io)) |file| {
        if (file.kind != .file) continue;
        const path = try allocator.dupeSentinel(u8, file.path, 0);
        // Windows 宿主也使用资源接口约定的正斜杠路径。
        std.mem.replaceScalar(u8, path, '\\', '/');
        const hash = std.hash.Fnv1a_32.hash(path);
        const entry = try pathsByHash.getOrPut(allocator, hash);
        if (entry.found_existing) {
            std.debug.panic("asset hash conflict: {s} and {s} ({x})", .{
                entry.value_ptr.*, path, hash,
            });
        }
        entry.value_ptr.* = path;
        try entries.append(allocator, .{ .path = path, .hash = hash });
    }
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

    const output = try cwd.createFile(io, args[2], .{});
    defer output.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = output.writer(io, &buffer);
    const bytes = &writer.interface;

    var archiveSize: u32 = 0; // 只计算资源包，不包含原始程序。
    for (entries.items) |*entry| {
        entry.offset = archiveSize;

        const file = try assets.openFile(io, entry.path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        entry.size = @intCast(try bytes.sendFileAll(&reader, .unlimited));
        archiveSize += entry.size;
    }

    // 每条索引 12 字节：FNV-1a 32 路径哈希、偏移和大小，整数采用小端序。
    for (entries.items) |entry| {
        try bytes.writeInt(u32, entry.hash, .little);
        try bytes.writeInt(u32, entry.offset, .little);
        try bytes.writeInt(u32, entry.size, .little);
        archiveSize += 12;
    }
    archiveSize += 12;
    try bytes.writeInt(u32, @intCast(entries.items.len), .little);
    try bytes.writeInt(u32, archiveSize, .little);
    try bytes.writeAll("b0b0");
    try writer.flush();
}
