const std = @import("std");

// 真机与模拟器各自使用完整的头文件和链接描述集合。
pub fn add(
    b: *std.Build,
    zhu: *std.Build.Module,
    sokol: *std.Build.Step.Compile,
) !std.Build.LazyPath {
    const target = zhu.resolved_target.?.result;
    const name = if (target.abi == .simulator) "simulator" else "device";
    const root = b.fmt("sdk/ios/{s}", .{name});
    // 头文件和完整 libSystem 留在 SDK，精简链接描述随代码维护。
    const links = b.fmt("sdk/defs/ios/{s}", .{name});
    for ([_]*std.Build.Module{ zhu, sokol.root_module }) |module| {
        module.addSystemIncludePath(b.path(b.pathJoin(&.{ root, "usr/include" })));
        module.addSystemFrameworkPath(b.path(b.pathJoin(&.{
            links, "System/Library/Frameworks",
        })));
        module.addLibraryPath(b.path(b.pathJoin(&.{ links, "usr/lib" })));
        module.addLibraryPath(b.path(b.pathJoin(&.{ root, "usr/lib" })));
    }
    // 精简 TBD 直接链接原来由其他框架重导出的接口。
    zhu.linkFramework("CoreFoundation", .{});
    zhu.linkFramework("AVFAudio", .{});
    zhu.linkSystemLibrary("objc", .{ .use_pkg_config = .no });
    const file = try libcFile(b, target);
    sokol.setLibCFile(file);
    return file;
}

// 最终产物和 Sokol 使用同一平台的 libc，避免混用真机与模拟器符号。
pub fn libcFile(b: *std.Build, target: std.Target) !std.Build.LazyPath {
    const name = if (target.abi == .simulator) "simulator" else "device";
    const sdk = try b.root.joinString(
        b.allocator,
        b.fmt("sdk/ios/{s}", .{name}),
    );
    const include = b.pathJoin(&.{ sdk, "usr", "include" });
    const lib = b.pathJoin(&.{ sdk, "usr", "lib" });
    const text = b.fmt(
        "include_dir={0s}\nsys_include_dir={0s}\ncrt_dir={1s}\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ncc_dir=\n" ++
            "darwin_sdk_dir={2s}\n",
        .{ include, lib, sdk },
    );
    const files = b.addWriteFiles();
    return files.add(b.fmt("ios-{s}-libc.txt", .{name}), text);
}
