const std = @import("std");

// 使用 zon 中的微软 SDK，为 MSVC 构建配置头文件和真实运行库。
pub fn add(
    b: *std.Build,
    zhu: *std.Build.Module,
    sokol: *std.Build.Step.Compile,
) !std.Build.LazyPath {
    const arch = switch (zhu.resolved_target.?.result.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        else => return error.UnsupportedWindowsArch,
    };
    const sdk = try b.dependencyLazy("sdk_windows", .{});
    // 引擎中的 C 导入与 Sokol 使用同一组头文件。
    for ([_]*std.Build.Module{ zhu, sokol.root_module }) |module| {
        inline for (.{
            "crt/include",
            "sdk/include/ucrt",
            "sdk/include/um",
            "sdk/include/shared",
        }) |path| {
            module.addSystemIncludePath(sdk.path(path));
        }
    }

    // 最终程序和 Sokol 共用 libc 配置，库目录随目标架构选择。
    const root = try sdk.builder.root.joinString(b.allocator, "");
    const text = b.fmt(
        "include_dir={0s}/sdk/include/ucrt\n" ++
            "sys_include_dir={0s}/crt/include\n" ++
            "crt_dir={0s}/sdk/lib/ucrt/{1s}\n" ++
            "msvc_lib_dir={0s}/crt/lib/{1s}\n" ++
            "kernel32_lib_dir={0s}/sdk/lib/um/{1s}\n" ++
            "cc_dir=\ndarwin_sdk_dir=\n",
        .{ root, arch },
    );
    const files = b.addWriteFiles();
    const file = files.add("windows-libc.txt", text);
    sokol.setLibCFile(file);
    return file;
}
