const std = @import("std");

// 交叉构建只使用包内材料，引擎、Sokol 和最终产物共用 libc 配置。
pub fn add(
    b: *std.Build,
    zhu: *std.Build.Module,
    sokol: *std.Build.Step.Compile,
) !std.Build.LazyPath {
    const target = zhu.resolved_target.?.result;
    const arch = switch (target.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => return error.UnsupportedAndroidTarget,
    };
    const root = try b.root.joinString(b.allocator, "sdk/android");
    const include = b.pathJoin(&.{ root, "usr", "include" });
    const archInclude = b.pathJoin(&.{ include, arch });
    const libraries = b.pathJoin(&.{
        root,
        "usr",
        "lib",
        arch,
        b.fmt("{d}", .{target.os.version_range.linux.android}),
    });
    for ([_]*std.Build.Module{ zhu, sokol.root_module }) |module| {
        module.addSystemIncludePath(.{ .cwd_relative = include });
        module.addSystemIncludePath(.{ .cwd_relative = archInclude });
        module.addLibraryPath(.{ .cwd_relative = libraries });
    }
    const config = b.fmt(
        "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\ncc_dir={s}\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir=\n",
        .{ include, archInclude, libraries, libraries },
    );
    const file = b.addWriteFiles().add("android-libc.conf", config);
    sokol.setLibCFile(file);

    // 系统库改为引擎模块的文件输入，传递到测试和应用的最终链接。
    // Sokol 静态库不会传递文件输入，因此统一加到引擎模块。
    // TODO: Zig 修复库路径参数后移除转换。
    // https://codeberg.org/ziglang/zig/issues/37257
    for ([_]*std.Build.Module{ zhu, sokol.root_module }) |module| {
        var index: usize = 0;
        while (index < module.link_objects.items.len) {
            switch (module.link_objects.items[index]) {
                .system_lib => |system| {
                    const path = b.pathJoin(&.{
                        libraries, b.fmt("lib{s}.so", .{system.name}),
                    });
                    _ = module.link_objects.orderedRemove(index);
                    zhu.addObjectFile(.{ .cwd_relative = path });
                },
                else => index += 1,
            }
        }
    }
    return file;
}

// 游戏提供动态库名称和模块，安卓平台配置由引擎统一处理。
pub const AndroidOptions = struct {
    name: []const u8,
    root_module: *std.Build.Module,
};

// 在游戏构建缓存中补充安卓入口配置，生成 NativeActivity 加载的动态库。
pub fn buildAndroid(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: AndroidOptions,
) !*std.Build.Step.Compile {
    const mod = options.root_module;
    const zhu = dep.module("zhu");
    // 按模块对象查找游戏设置的导入名，不要求用户使用固定别名。
    var imports = mod.import_table.iterator();
    const importName = while (imports.next()) |entry| {
        if (entry.value_ptr.* == zhu) break entry.key_ptr.*;
    } else "zhu";
    // 追踪游戏入口内容，从模块本身取得源码路径和所属项目。
    const rootFile = mod.root_source_file.?;
    const src = rootFile.src_path;
    b.dependOnFileContents(rootFile);
    const path = try src.owner.root.joinString(b.allocator, src.sub_path);
    const source = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, //
        path, b.allocator, .unlimited);
    // 完整复制源码目录，保留所有文件和原有的相对导入关系。
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(rootFile.dirname(), "", .{});
    mod.root_source_file = files.add("zhuyu_android_main.zig", //
        b.fmt("{0s}\n\n// 动态库显式分析窗口模块，保留引擎导出的入口和回调。\n" ++
            "comptime {{\n    _ = @import(\"{1f}\").window;\n}}\n\n" ++
            "// 安卓日志和 panic 由引擎直接输出到 Logcat。\n" ++
            "pub const std_options: @import(\"std\").Options = .{{\n" ++
            "    // 沿用安卓系统的备用信号栈，缩减动态库体积。\n" ++
            "    .signal_stack_size = null,\n" ++
            "    .logFn = @import(\"{1f}\").android.log,\n}};\n" ++
            "pub const panic = @import(\"{1f}\").android.panic;\n", .{
            source,
            std.zig.fmtString(importName),
        }));

    // 最终动态库与引擎使用同一开发环境。
    mod.pic = true;
    mod.link_libc = true;
    const lib = b.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .root_module = mod,
    });
    setLibC(dep, lib);
    lib.link_z_defs = true;
    lib.link_z_max_page_size = 16384;
    lib.link_z_common_page_size = 16384;
    return lib;
}

// 最终产物复用 Sokol 的 libc 配置；没有包内配置时保留原设置。
pub fn setLibC(
    dep: *std.Build.Dependency,
    artifact: *std.Build.Step.Compile,
) void {
    // 从实际导入模块取产物，避免重新创建选项不同的 Sokol 依赖。
    const sokolModule = dep.module("zhu").import_table.get("sokol").?;
    for (sokolModule.link_objects.items) |object| {
        switch (object) {
            .other_step => |library| {
                if (!std.mem.eql(u8, library.name, "sokol_clib")) continue;
                if (library.libc_file) |file| artifact.setLibCFile(file);
                return;
            },
            else => {},
        }
    }
    // ZhuYu 的 Sokol 模块必须链接自身的 C 实现。
    unreachable;
}
