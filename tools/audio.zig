//! 将 MP3/WAV 转为 Ogg Vorbis，按需重采样 OGG，其他文件原样拷贝。
const std = @import("std");
const Build = std.Build;
const Dependency = Build.Dependency;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    input: []const u8, // 相对于游戏项目的原始音频目录，递归扫描。
    output: []const u8 = "assets/audio", // 工具独占的输出目录，每次清空重建。
    rate: u32 = 44100, // MP3/WAV/OGG 的目标采样率，需与游戏输出一致。
    exe: []const u8 = "ffmpeg",
    probe: []const u8 = "ffprobe",
    name: []const u8 = "audio",
};

// 只在显式执行 audio 时扫描和转码，普通构建不调用 FFmpeg。
pub fn addStep(b: *Build, dep: *Dependency, options: Options) !void {
    const tool = b.addExecutable(.{
        .name = "zhuyu-audio",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/audio.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const step = b.addRunArtifact(tool);
    step.setCwd(b.path("."));
    for ([_][]const u8{ options.input, options.output }) |path| {
        step.addArg(try b.root.joinString(b.allocator, path));
    }
    step.addArgs(&.{ b.fmt("{d}", .{options.rate}), options.exe, options.probe });
    // 每次生成都重新扫描，移除源目录已删除的音频。
    step.has_side_effects = true;
    b.step(options.name, "Convert and copy audio assets").dependOn(&step.step);
}

// 参数依次为输入目录、输出目录、采样率、FFmpeg 和 ffprobe 路径。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const cwd = Dir.cwd();
    var input = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer input.close(io);
    var walker = try input.walk(gpa);
    defer walker.deinit();

    // 输出目录由工具独占，每次清空后直接生成。
    try cwd.deleteTree(io, args[2]);
    try cwd.createDirPath(io, args[2]);
    var converted: usize = 0;
    var copied: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const extension = std.fs.path.extension(entry.path);
        const encode = std.ascii.eqlIgnoreCase(extension, ".mp3") or
            std.ascii.eqlIgnoreCase(extension, ".wav");
        const ogg = std.ascii.eqlIgnoreCase(extension, ".ogg");
        const source = try std.fs.path.join(gpa, &.{ args[1], entry.path });
        const relative = if (encode)
            try std.fmt.allocPrint(gpa, "{s}.ogg", .{
                entry.path[0 .. entry.path.len - extension.len],
            })
        else
            entry.path;
        const destination = try std.fs.path.join(gpa, &.{ args[2], relative });
        try cwd.createDirPath(io, std.fs.path.dirname(destination).?);

        // 已有 OGG 仅在采样率不同时重新编码，避免无必要的有损转码。
        var convert = encode;
        if (ogg) {
            const rate = try run(gpa, io, &.{
                args[5],
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=sample_rate",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                source,
            });
            convert = !std.mem.eql(u8, std.mem.trim(u8, rate, " \t\r\n"), args[3]);
        }

        if (convert) {
            // 固定输出 Vorbis；拒绝覆盖同名资源，不等待终端输入。
            _ = try run(gpa, io, &.{
                args[4], "-nostdin",  "-v",   "error",     "-n",   "-i", source,
                "-map",  "0:a:0",     "-c:a", "libvorbis", "-q:a", "4",  "-ar",
                args[3], destination,
            });
            converted += 1;
            std.log.info("converted {s} -> {s}", .{ entry.path, relative });
        } else {
            // MIDI 和其他格式原样保留；与转码结果同名时直接报错。
            try cwd.copyFile(source, cwd, destination, io, .{ .replace = false });
            copied += 1;
            std.log.info("copied {s}", .{entry.path});
        }
    }
    std.log.info("converted {} files, copied {} files, rate={s}", .{
        converted, copied, args[3],
    });
}

// 两种外部命令共用退出检查，失败时显示原始错误并停止生成。
fn run(gpa: Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    if (!result.term.success()) {
        std.log.err("{s} {f}: {s}", .{ argv[0], result.term, result.stderr });
        return error.AudioCommandFailed;
    }
    return result.stdout;
}
