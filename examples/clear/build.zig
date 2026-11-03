const std = @import("std");
const zhuBuild = @import("zhuyu");

// 构建独立的清屏示例，平台接入复用引擎接口。
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zhuyu = b.dependency("zhuyu", .{
        .target = target,
        .optimize = optimize,
        .font = b.option(zhuBuild.FontMode, "font", "Font mode") orelse .bitmap,
        .samplers = b.option(bool, "samplers", "Use two samplers") orelse false,
        .gles3 = b.option(bool, "gles3", "Use GLES3 on Linux") orelse false,
    });
    zhuBuild.installEmsdk(b, zhuyu);

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zhu", .module = zhuyu.module("zhu") }},
    });

    if (target.result.abi.isAndroid()) {
        const lib = try zhuBuild.buildAndroid(b, zhuyu, .{
            .name = "clear",
            .root_module = mod,
        });
        b.installArtifact(lib);
    } else if (target.result.os.tag == .emscripten) {
        const web = try zhuBuild.buildWeb(b, zhuyu, .{
            .name = "clear",
            .root_module = mod,
        });
        b.getInstallStep().dependOn(&web.step);
    } else {
        const exe = b.addExecutable(.{ .name = "clear", .root_module = mod });
        zhuBuild.setLibC(zhuyu, exe);
        if (target.result.os.tag == .windows and target.result.abi == .msvc)
            exe.entry = .{ .symbol_name = "mainCRTStartup" };
        b.installArtifact(exe);

        // 构建只生成程序，由 run 命令显式运行。
        const run = b.addRunArtifact(exe);
        b.step("run", "Run the example").dependOn(&run.step);
    }
}
