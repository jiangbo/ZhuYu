const std = @import("std");

// 应用直接使用同一版本的 Sokol 构建工具。
pub const sokol = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = target.result.os.tag == .emscripten;
    // 编译期决定菜单文字是否自动使用 MSDF 管线。
    const useMsdf = b.option(bool, "msdf", "Use MSDF for menu text") orelse false;
    // 应用创建依赖时传入，默认关闭程序尾部的资源探测和追加。
    const append = b.option(bool, "append", "Append asset pack") orelse false;
    // 不使用 MIDI 的应用不编译播放器和内置音色。
    const midi = b.option(bool, "midi", "Enable MIDI music") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "msdf", useMsdf);
    options.addOption(bool, "append", append);
    options.addOption(bool, "midi", midi);

    const sokolDep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokolModule = sokolDep.module("sokol");
    const shader = try createShader(b, sokolDep, target.result);

    const zhu = b.addModule("zhu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Web 由 emcc 链接，关闭 C 的 UBSan。
        .sanitize_c = if (web) .off else null,
    });
    zhu.addImport("sokol", sokolModule);
    zhu.addImport("shader", shader);
    zhu.addOptions("options", options);
    if (web) {
        const em = sokolDep.builder.dependency("emsdk", .{});
        const include = em.path("upstream/emscripten/cache/sysroot/include");
        zhu.addSystemIncludePath(include);
        // 静态接入浏览器存档函数，无需应用额外配置链接参数。
        zhu.addCSourceFile(.{ .file = b.path("src/internal/web.c") });
    }

    const tests = b.addTest(.{ .root_module = zhu });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&runTests.step);
}

// BMFont 的参数和生成流程由工具自身管理。
pub const bmfont = struct {
    pub const Options = @import("tools/bmfont.zig").Options;
    pub const addStep = @import("tools/bmfont.zig").addStep;
};

// MSDF 的参数和生成流程由工具自身管理。
pub const msdf = struct {
    pub const Options = @import("tools/msdf.zig").Options;
    pub const addStep = @import("tools/msdf.zig").addStep;
};

// 资源转换工具在宿主上运行，按需注册游戏项目的构建命令。
pub const atlas = struct {
    pub const Options = @import("tools/atlas.zig").Options;
    pub const addStep = @import("tools/atlas.zig").addStep;
};

pub const tiled = struct {
    pub const Options = @import("tools/tiled.zig").Options;
    pub const addStep = @import("tools/tiled.zig").addStep;
};

// 游戏提供程序名称、模块和解压后的 macOS SDK 根目录。
pub const MacOSOptions = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    sdk: []const u8, // 指向 MacOSX*.sdk，而不是其上级目录。
};

// 为目标程序和 Sokol 配置同一套 SDK，宿主平台的打包工具不受影响。
pub fn buildMacOS(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: MacOSOptions,
) *std.Build.Step.Compile {
    const mod = options.root_module;
    const zhu = dep.module("zhu");
    const sokolDep = dep.builder.dependency("sokol", .{
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });
    const sokolLib = sokolDep.artifact("sokol_clib");
    const include = b.pathJoin(&.{ options.sdk, "usr", "include" });
    const libraries = b.pathJoin(&.{ options.sdk, "usr", "lib" });
    const frameworks = b.pathJoin(&.{
        options.sdk, "System", "Library", "Frameworks",
    });
    for ([_]*std.Build.Module{ mod, zhu, sokolLib.root_module }) |module| {
        module.addSystemIncludePath(.{ .cwd_relative = include });
        module.addSystemFrameworkPath(.{ .cwd_relative = frameworks });
        module.addLibraryPath(.{ .cwd_relative = libraries });
    }

    // libc 配置由 SDK 路径直接生成到缓存，游戏无需维护额外文件。
    const config = b.fmt(
        "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\ncc_dir=\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir={s}\n",
        .{ include, include, libraries, options.sdk },
    );
    const libc = b.addWriteFiles().add("macos-libc.conf", config);
    sokolLib.setLibCFile(libc);
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = mod,
    });
    exe.setLibCFile(libc);
    return exe;
}

// 注册 pack 命令，通过 append 选项控制是否自动追加资源包。
pub fn addPackStep(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: struct {
        exe: *std.Build.Step.Compile,
        assets: []const u8 = "assets", // 相对于游戏项目的资源目录。
        output: []const u8 = "assets.pack", // 独立资源包的输出名称。
    },
) void {
    const tool = b.addExecutable(.{
        .name = "zhuyu-pack",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/pack.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const pack = b.addRunArtifact(tool);
    // 打包命令每次读取当前资源，不登记资源变化依赖。
    pack.has_side_effects = true;
    pack.addDirectoryArg(b.path(options.assets));
    const output = pack.addOutputFileArg(options.output);
    const install = b.addInstallFile(output, options.output);
    b.step("pack", "Pack assets")
        .dependOn(&install.step);

    // 依赖的布尔参数保存为字符串，未传入时保持关闭。
    const opt = dep.builder.user_input_options.get("append") orelse return;
    if (!std.mem.eql(u8, opt.scalar, "true")) return;

    // pack 不限制目标平台，append 面向三个桌面系统。
    const target = options.exe.rootModuleTarget();
    if (target.os.tag != .windows and target.os.tag != .macos and
        (target.os.tag != .linux or target.abi.isAndroid())) return;

    const appendTool = b.addExecutable(.{
        .name = "zhuyu-append",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("tools/append.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const append = b.addRunArtifact(appendTool);
    // 文件参数自动建立依赖：先编译程序、生成 pack，再执行追加。
    append.addArtifactArg(options.exe);
    append.addFileArg(output);
    const name = b.fmt("{s}-packed{s}", .{
        options.exe.name, target.exeFileExt(),
    });
    const program = append.addOutputFileArg(name);
    const installProgram = b.addInstallBinFile(program, name);
    b.getInstallStep().dependOn(&installProgram.step);
}

// 游戏提供动态库名称和模块，安卓平台配置由引擎统一处理。
pub const AndroidOptions = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    ndk: []const u8, // Android NDK 目录，由游戏构建选项传入。
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

    // 配置引擎和 Sokol 使用的 NDK、系统库及 APK 资源读取。
    const target = zhu.resolved_target.?;
    // 取回创建引擎依赖时使用的同一份 Sokol，配置在实际编译前生效。
    const sokolDep = dep.builder.dependency("sokol", .{
        .target = target,
        .optimize = zhu.optimize.?,
    });

    const host = switch (b.graph.host.result.os.tag) {
        .windows => "windows-x86_64",
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        else => @panic("Unsupported NDK host"),
    };
    const sysroot = b.pathJoin(&.{
        options.ndk,
        "toolchains",
        "llvm",
        "prebuilt",
        host,
        "sysroot",
    });
    const include = b.pathJoin(&.{ sysroot, "usr", "include" });
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => return error.UnsupportedAndroidTarget,
    };
    const archInclude = b.pathJoin(&.{ include, arch });
    const libraries = b.pathJoin(&.{
        sysroot,
        "usr",
        "lib",
        arch,
        b.fmt("{d}", .{target.result.os.version_range.linux.android}),
    });
    // 引擎和 Sokol 使用同一套 NDK，最终动态库复用这份链接配置。
    const sokolLib = sokolDep.artifact("sokol_clib");
    for ([_]*std.Build.Module{ zhu, sokolLib.root_module }) |module| {
        module.addSystemIncludePath(.{ .cwd_relative = include });
        module.addSystemIncludePath(.{ .cwd_relative = archInclude });
        module.addLibraryPath(.{ .cwd_relative = libraries });
        module.pic = true;
    }
    const config = b.fmt(
        "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\ncc_dir={s}\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir=\n",
        .{ include, archInclude, libraries, libraries },
    );
    const libc = b.addWriteFiles().add("android-libc.conf", config);
    sokolLib.setLibCFile(libc);
    // GLES、EGL、android、log 继续由 Sokol 声明。
    zhu.linkSystemLibrary("aaudio", .{});
    zhu.linkSystemLibrary("m", .{});
    // 系统库改为最终动态库的文件输入，绕过 Zig 的 LLD 库路径参数问题。
    // TODO: Zig 修复后，验证系统库声明可直接链接，再移除下面的转换。
    // https://codeberg.org/ziglang/zig/issues/37257
    // 文件输入不会像系统库声明一样从 Sokol 静态库传递到最终链接。
    for ([_]*std.Build.Module{ zhu, sokolLib.root_module }) |module| {
        var index: usize = 0;
        while (index < module.link_objects.items.len) {
            switch (module.link_objects.items[index]) {
                .system_lib => |system| {
                    mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{
                        libraries, b.fmt("lib{s}.so", .{system.name}),
                    }) });
                    _ = module.link_objects.orderedRemove(index);
                },
                else => index += 1,
            }
        }
    }

    // 游戏动态库直接复用同一份库路径和 libc 配置。
    mod.pic = true;
    mod.link_libc = true;
    mod.addLibraryPath(.{ .cwd_relative = libraries });
    const lib = b.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .root_module = mod,
    });
    lib.setLibCFile(libc);
    lib.link_z_defs = true;
    lib.link_z_max_page_size = 16384;
    lib.link_z_common_page_size = 16384;
    return lib;
}

fn createShader(
    b: *std.Build,
    sokolDep: *std.Build.Dependency,
    target: std.Target,
) !*std.Build.Module {
    const sokolModule = sokolDep.module("sokol");
    return try sokol.shdc.createModule(b, "shader", sokolModule, .{
        .shdc_dep = sokolDep.builder.dependency("shdc", .{}),
        .input = "src/internal/quad.glsl",
        .output = "quad.glsl.zig",
        // 保留对应平台可能使用的 shader 格式。
        .slang = switch (target.os.tag) {
            .windows => .{ .hlsl5 = true, .glsl410 = true },
            .macos => .{ .metal_macos = true, .glsl410 = true },
            .ios => if (target.abi == .simulator)
                .{ .metal_sim = true }
            else
                .{ .metal_ios = true },
            .linux => if (target.abi.isAndroid())
                .{ .glsl300es = true }
            else
                .{ .glsl410 = true },
            .emscripten => .{ .glsl300es = true, .wgsl = true },
            else => return error.UnsupportedShaderTarget,
        },
    });
}
