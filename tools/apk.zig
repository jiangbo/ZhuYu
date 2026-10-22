const std = @import("std");
const Build = std.Build;
const WriteFile = Build.Step.WriteFile;

// Android 应用的名称、标识、外观和窗口行为。
pub const AppConfig = struct {
    package: []const u8, // Android 应用 ID。
    label: []const u8, // 启动器中显示的名称。
    icon: Build.LazyPath, // 安装后启动器显示的图标，使用 PNG 图片。
    orientation: enum { landscape, portrait, unspecified } = .landscape,
    iconColor: []const u8 = "#FFFFFF", // 自适应图标的背景颜色。
};

// 打包输入、工具与发布版本独立于 Android 应用配置。
pub const Options = struct {
    lib: *Build.Step.Compile,
    sdk: ?[]const u8 = null, // 未指定时读取 ANDROID_HOME 环境变量。
    assets: []const u8 = "assets", // 相对于游戏项目的资源目录。
    compressLib: bool = true, // 压缩动态库，由系统在安装时解压。
    compressAssets: bool = true, // 压缩游戏资源，由系统在读取时解压。
    versionCode: u32 = 1,
    versionName: []const u8 = "0.1.0",
    app: AppConfig,
};

// 注册 apk 步骤，保留独立动态库构建，不依赖 Gradle 和 Android Studio。
pub fn addStep(b: *Build, options: Options) !void {
    // 环境变量变化无法由配置缓存追踪，自动查找时每次重新执行配置。
    if (options.sdk == null) b.graph.poisonCache();
    const sdk = options.sdk orelse b.graph.environ_map.get("ANDROID_HOME") orelse
        return error.AndroidSdkNotFound;
    const toolsVersion = try findBuildTools(b, sdk);
    const tools = b.pathJoin(&.{ sdk, "build-tools", toolsVersion });
    const targetSdk = try findPlatform(b, sdk);
    const resources = compileResources(b, .{
        .xml = createResources(b, options, targetSdk),
        .tools = tools,
        .androidJar = .{ .cwd_relative = b.pathJoin(&.{
            sdk,           "platforms", b.fmt("android-{d}", .{targetSdk}),
            "android.jar",
        }) },
        .debug = options.lib.root_module.optimize == .debug,
    });
    const unsigned = packApk(b, options, .{ .resources = resources, .tools = tools });
    const apk = try signApk(b, .{
        .name = options.lib.name,
        .tools = tools,
        .apk = unsigned,
    });
    const install = b.addInstallFile(apk, b.fmt("apk/{s}.apk", .{options.lib.name}));
    b.step("apk", "Build a debug-signed Android APK").dependOn(&install.step);
}

// 生成 Manifest、图标图片及图标颜色配置。
fn createResources(b: *Build, options: Options, targetSdk: u32) *WriteFile {
    const app = options.app;
    // Manifest 与图标资源仅写入构建缓存，游戏无需维护 XML。
    const xml = b.addWriteFiles();
    _ = xml.add("AndroidManifest.xml", b.fmt(manifestXml, .{
        app.package,
        options.versionCode,
        options.versionName,
        // 最低 API 来自原生库目标，目标 API 来自已安装的 SDK Platform。
        options.lib.rootModuleTarget().os.version_range.linux.android,
        targetSdk,
        options.compressLib,
        app.label,
        @tagName(app.orientation),
        options.lib.name,
    }));
    _ = xml.addCopyFile(app.icon, "res/mipmap-xxxhdpi/ic_launcher_foreground.png");
    // Android 自适应图标：将游戏图标作为前景，颜色资源作为背景。
    _ = xml.add("res/mipmap-anydpi-v26/ic_launcher.xml",
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
        \\    <background android:drawable="@color/ic_launcher_background" />
        \\    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
        \\</adaptive-icon>
        \\
    );
    // 定义图标布局引用的背景颜色，值来自 app.iconColor。
    _ = xml.add("res/values/colors.xml", b.fmt(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<resources>
        \\    <color name="ic_launcher_background">{s}</color>
        \\</resources>
        \\
    , .{app.iconColor}));

    return xml;
}

// AAPT2 编译图片和颜色资源，链接为尚未加入动态库与游戏资源的 APK。
fn compileResources(b: *Build, options: struct {
    xml: *WriteFile,
    tools: []const u8,
    androidJar: Build.LazyPath,
    debug: bool,
}) Build.LazyPath {
    const windows = b.graph.host.result.os.tag == .windows;
    // AAPT2 编译图标和颜色，再合并 Manifest。
    const aapt: Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{
        options.tools, if (windows) "aapt2.exe" else "aapt2",
    }) };
    const compile = b.addRunFile(aapt);
    compile.addArgs(&.{ "compile", "--dir" });
    compile.addDirectoryArg(options.xml.getDirectory().path(b, "res"));
    compile.addArg("-o");
    const resources = compile.addOutputFileArg("resources.zip");
    const link = b.addRunFile(aapt);
    link.addArgs(&.{ "link", "--manifest" });
    link.addFileArg(options.xml.getDirectory().path(b, "AndroidManifest.xml"));
    link.addArg("-I");
    link.addFileArg(options.androidJar);
    if (options.debug) link.addArg("--debug-mode");
    link.addArg("-o");
    const resourceApk = link.addOutputFileArg("resources.apk");
    link.addFileArg(resources);

    return resourceApk;
}

// 合入动态库和游戏资源，再进行 16 KiB 对齐，为签名准备完整 APK。
fn packApk(b: *Build, options: Options, input: struct {
    resources: Build.LazyPath,
    tools: []const u8,
}) Build.LazyPath {
    const windows = b.graph.host.result.os.tag == .windows;
    const files = b.addWriteFiles();
    const abi = switch (options.lib.rootModuleTarget().cpu.arch) {
        .aarch64 => "arm64-v8a",
        .arm, .thumb => "armeabi-v7a",
        .x86 => "x86",
        .x86_64 => "x86_64",
        else => @panic("Unsupported Android ABI"),
    };
    _ = files.addCopyFile(options.lib.getEmittedBin(), b.fmt(
        "lib/{s}/lib{s}.so",
        .{ abi, options.lib.name },
    ));
    // 游戏资源由 jar 加入，保证 Windows 生成的 ZIP 路径也使用斜杠。
    _ = files.addCopyDirectory(b.path(options.assets), "assets", .{});

    // 只修改临时副本，避免污染 AAPT2 的缓存输出。
    const temp = b.addWriteFiles();
    temp.mode = .tmp;
    const unsigned = temp.addCopyFile(input.resources, "unsigned.apk");
    // 两次合入依次修改同一 APK，分别应用动态库与游戏资源的压缩设置。
    var last: *Build.Step = &temp.step;
    for ([_]struct { path: []const u8, compress: bool }{
        .{ .path = "lib", .compress = options.compressLib },
        .{ .path = "assets", .compress = options.compressAssets },
    }) |entry| {
        const merge = b.addSystemCommand(&.{ "jar", "--update" });
        if (!entry.compress) merge.addArg("--no-compress");
        merge.addArg("--file");
        merge.has_side_effects = true;
        merge.addFileArg(unsigned);
        merge.addArg("-C");
        merge.addDirectoryArg(files.getDirectory());
        merge.addArg(entry.path);
        merge.step.dependOn(last);
        last = &merge.step;
    }

    // 未压缩的动态库按 16 KiB 页对齐，签名后不再修改 APK。
    const zipalign = b.addRunFile(.{ .cwd_relative = b.pathJoin(&.{
        input.tools, if (windows) "zipalign.exe" else "zipalign",
    }) });
    zipalign.addArgs(&.{ "-P", "16", "-f", "4" });
    zipalign.addFileArg(unsigned);
    const aligned = zipalign.addOutputFileArg("aligned.apk");
    zipalign.step.dependOn(last);

    return aligned;
}

// 创建或复用调试密钥，对已完成组包和对齐的 APK 签名。
fn signApk(b: *Build, options: struct {
    name: []const u8,
    tools: []const u8,
    apk: Build.LazyPath,
}) !Build.LazyPath {
    const windows = b.graph.host.result.os.tag == .windows;
    // 复用 Android 默认调试密钥路径；新证书的身份描述标记 ZhuYu。
    const home = b.graph.environ_map.get(if (windows) "USERPROFILE" else "HOME").?;
    const key: Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{
        home, ".android", "debug.keystore",
    }) };
    var keyStep: ?*Build.Step = null;
    std.Io.Dir.cwd().access(b.graph.io, key.cwd_relative, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        try std.Io.Dir.cwd().createDirPath(b.graph.io, b.pathJoin(&.{
            home, ".android",
        }));
        const keytool = b.addSystemCommand(&.{ "keytool", "-genkeypair" });
        keytool.addArgs(&.{
            "-keystore",  key.cwd_relative,
            "-storetype", "JKS",
            "-storepass", "android",
            "-keypass",   "android",
            "-alias",     "androiddebugkey",
            "-keyalg",    "RSA",
            "-keysize",   "2048",
            "-validity",  "10000",
            "-dname",     "CN=ZhuYu Debug,O=ZhuYu",
        });
        keytool.has_side_effects = true;
        keyStep = &keytool.step;
    };
    const sign = b.addSystemCommand(&.{
        "java", "--enable-native-access=ALL-UNNAMED", "-jar",
    });
    sign.addFileArg(.{ .cwd_relative = b.pathJoin(&.{
        options.tools, "lib", "apksigner.jar",
    }) });
    sign.addArg("sign");
    sign.addArg("--ks");
    sign.addFileArg(key);
    sign.addArgs(&.{
        "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android",
        "--key-pass",     "pass:android",    "--out",
    });
    const apk = sign.addOutputFileArg(b.fmt("{s}.apk", .{options.name}));
    sign.addFileArg(options.apk);
    if (keyStep) |step| sign.step.dependOn(step);
    return apk;
}

// 按语义版本选择 Build Tools，安装或删除版本后重新执行构建配置。
fn findBuildTools(b: *Build, sdk: []const u8) ![]const u8 {
    const path = b.pathJoin(&.{ sdk, "build-tools" });
    b.dependOnDirectoryContents(.{ .cwd_relative = path });
    const io = b.graph.io;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var selected: ?[]const u8 = null;
    var latest: std.SemanticVersion = undefined;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const version = try std.SemanticVersion.parse(entry.name);
        if (selected == null or version.order(latest) == .gt) {
            selected = b.dupe(entry.name);
            latest = version;
        }
    }
    return selected orelse error.BuildToolsNotFound;
}

// 平台目录使用 android-API 命名，选择最高 API 作为构建和适配版本。
fn findPlatform(b: *Build, sdk: []const u8) !u32 {
    const path = b.pathJoin(&.{ sdk, "platforms" });
    b.dependOnDirectoryContents(.{ .cwd_relative = path });
    const io = b.graph.io;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var latest: ?u32 = null;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const name = std.mem.cutPrefix(u8, entry.name, "android-") orelse continue;
        const version = try std.fmt.parseUnsigned(u32, name, 10);
        if (latest == null or version > latest.?) latest = version;
    }
    return latest orelse error.PlatformNotFound;
}

// Manifest 固定模板，应用属性与版本在生成时填入。
const manifestXml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    \\    package="{s}" android:versionCode="{d}" android:versionName="{s}">
    \\    <uses-sdk android:minSdkVersion="{d}" android:targetSdkVersion="{d}" />
    \\    <uses-feature android:glEsVersion="0x00030001" android:required="true" />
    \\    <application android:allowBackup="false" android:hasCode="false"
    \\        android:extractNativeLibs="{}" android:icon="@mipmap/ic_launcher"
    \\        android:label="{s}"
    \\        android:theme="@android:style/Theme.Material.NoActionBar.Fullscreen">
    \\        <activity android:name="android.app.NativeActivity"
    \\            android:exported="true" android:launchMode="singleTask"
    \\            android:screenOrientation="{s}"
    \\            android:configChanges=
    \\                "orientation|screenSize|screenLayout|keyboardHidden">
    \\            <meta-data android:name="android.app.lib_name"
    \\                android:value="{s}" />
    \\            <meta-data android:name="android.app.func_name"
    \\                android:value="zhuyu_main" />
    \\            <intent-filter>
    \\                <action android:name="android.intent.action.MAIN" />
    \\                <category android:name="android.intent.category.LAUNCHER" />
    \\            </intent-filter>
    \\        </activity>
    \\    </application>
    \\</manifest>
    \\
;
