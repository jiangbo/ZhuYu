const std = @import("std");

// 参数依次为原始程序、资源包、输出程序。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cwd = std.Io.Dir.cwd();
    const output = try cwd.createFile(io, args[3], .{
        .permissions = .executable_file,
    });
    defer output.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = output.writer(io, &buffer);

    // 依次复制程序和资源包，原始输入文件保持不变。
    for (args[1..3]) |path| {
        const file = try cwd.openFile(io, path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        _ = try writer.interface.sendFileAll(&reader, .unlimited);
    }
    try writer.flush();
}
