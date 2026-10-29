const std = @import("std");

// 头文件来自 SDK 材料，精简链接描述独立维护，运行时加载系统框架。
pub fn add(
    b: *std.Build,
    zhu: *std.Build.Module,
    sokol: *std.Build.Step.Compile,
) !std.Build.LazyPath {
    for ([_]*std.Build.Module{ zhu, sokol.root_module }) |module| {
        module.addSystemIncludePath(b.path("sdk/macos/usr/include"));
        module.addSystemFrameworkPath(b.path(
            "sdk/defs/macos/System/Library/Frameworks",
        ));
        module.addLibraryPath(b.path("sdk/defs/macos/usr/lib"));
        module.addLibraryPath(b.path("sdk/macos/usr/lib"));
    }
    // 精简 TBD 不包含重导出链，直接链接 Sokol 实际引用的框架和运行库。
    zhu.linkFramework("Foundation", .{});
    zhu.linkFramework("CoreFoundation", .{});
    zhu.linkSystemLibrary("objc", .{ .use_pkg_config = .no });
    const file = try libcFile(b);
    sokol.setLibCFile(file);
    return file;
}

// libc 和 SDK 版本属于最终编译步骤，不能仅通过模块的搜索路径传递。
pub fn libcFile(b: *std.Build) !std.Build.LazyPath {
    const sdk = try b.root.joinString(b.allocator, "sdk/macos");
    const include = b.pathJoin(&.{ sdk, "usr", "include" });
    const lib = b.pathJoin(&.{ sdk, "usr", "lib" });
    const text = b.fmt(
        "include_dir={0s}\nsys_include_dir={0s}\ncrt_dir={1s}\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ncc_dir=\n" ++
            "darwin_sdk_dir={2s}\n",
        .{ include, lib, sdk },
    );
    const files = b.addWriteFiles();
    return files.add("macos-libc.txt", text);
}
