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
    targetSdk: u32 = 36, // 适配版本独立于动态库目标指定的最低 API。
    assets: []const u8 = "assets", // 相对于游戏项目的资源目录。
    compressLib: bool = true, // 压缩动态库，由系统在安装时解压。
    compressAssets: bool = true, // 压缩游戏资源，由系统在读取时解压。
    versionCode: u32 = 1,
    versionName: []const u8 = "0.1.0",
    app: AppConfig,
};

// 注册 apk 步骤，使用包内 JAR；宿主只需安装 JDK 11 或以上。
pub fn addStep(b: *Build, dep: *Build.Dependency, options: Options) !void {
    const target = options.lib.rootModuleTarget();
    if (!target.abi.isAndroid()) return error.ExpectedAndroidTarget;
    if (options.targetSdk < target.os.version_range.linux.android)
        return error.TargetApiBelowMinimum;
    // ARSCLib 1.4.0 的内置 Android framework 最高为 API 36。
    if (options.targetSdk > 36) return error.UnsupportedTargetApi;
    const unsigned = try packApk(b, dep, options);
    const apk = try signApk(b, .{
        .name = options.lib.name,
        .signer = dep.path("sdk/apk/apksigner.jar"),
        .source = dep.path("tools/Sign.java"),
        .apk = unsigned,
    });
    const install = b.addInstallFile(apk, b.fmt("apk/{s}.apk", .{options.lib.name}));
    b.step("apk", "Build a debug-signed Android APK").dependOn(&install.step);
}

// 生成 Manifest、图标图片及图标颜色配置。
fn createResources(b: *Build, options: Options) !*WriteFile {
    const app = options.app;
    // Manifest 与图标资源仅写入构建缓存，游戏无需维护 XML。
    const xml = b.addWriteFiles();
    _ = xml.add("AndroidManifest.xml", b.fmt(manifestXml, .{
        try xmlText(b, app.package),
        options.versionCode,
        try xmlText(b, options.versionName),
        // 最低 API 来自原生库目标，目标 API 由打包参数指定。
        options.lib.rootModuleTarget().os.version_range.linux.android,
        options.targetSdk,
        options.compressLib,
        try xmlText(b, app.label),
        options.lib.root_module.optimize == .debug,
        @tagName(app.orientation),
        try xmlText(b, options.lib.name),
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
    , .{try xmlText(b, app.iconColor)}));

    // 同时追踪资源文件及目录变化，避免缓存遗漏新增或删除的 assets。
    _ = xml.addCopyDirectory(b.path(options.assets), "assets", .{});
    return xml;
}

// Java 源文件由 JDK 直接运行，资源编译、组包和对齐共用一次调用。
fn packApk(b: *Build, dep: *Build.Dependency, options: Options) !Build.LazyPath {
    const abi = switch (options.lib.rootModuleTarget().cpu.arch) {
        .aarch64 => "arm64-v8a",
        .arm, .thumb => "armeabi-v7a",
        .x86 => "x86",
        .x86_64 => "x86_64",
        else => return error.UnsupportedAndroidTarget,
    };
    const resources = try createResources(b, options);
    const pack = b.addSystemCommand(&.{
        "java", "-Dfile.encoding=UTF-8", "--class-path",
    });
    pack.addFileArg(dep.path("sdk/apk/ARSCLib.jar"));
    pack.addFileArg(dep.path("tools/Apk.java"));
    pack.addDirectoryArg(resources.getDirectory());
    pack.addArtifactArg(options.lib);
    pack.addArg(abi);
    pack.addDirectoryArg(resources.getDirectory().path(b, "assets"));
    pack.addArg(if (options.compressLib) "true" else "false");
    pack.addArg(if (options.compressAssets) "true" else "false");
    return pack.addOutputFileArg("unsigned.apk");
}

// 字符串写入 XML 属性前转义，保留中文名称及引号等字符。
fn xmlText(b: *Build, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (text) |char| {
        switch (char) {
            '&' => try result.appendSlice(b.allocator, "&amp;"),
            '<' => try result.appendSlice(b.allocator, "&lt;"),
            '>' => try result.appendSlice(b.allocator, "&gt;"),
            '"' => try result.appendSlice(b.allocator, "&quot;"),
            '\'' => try result.appendSlice(b.allocator, "&apos;"),
            else => try result.append(b.allocator, char),
        }
    }
    return result.toOwnedSlice(b.allocator);
}

// 创建或复用调试密钥，对已完成组包和对齐的 APK 签名。
fn signApk(b: *Build, options: struct {
    name: []const u8,
    signer: Build.LazyPath,
    source: Build.LazyPath,
    apk: Build.LazyPath,
}) !Build.LazyPath {
    // 调试密钥可在构建之外创建或删除，每次重新计算生成步骤。
    b.graph.poisonCache();
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
        "java", "-Dfile.encoding=UTF-8", "--class-path",
    });
    sign.addFileArg(options.signer);
    sign.addFileArg(options.source);
    sign.addFileArg(options.apk);
    const apk = sign.addOutputFileArg(b.fmt("{s}.apk", .{options.name}));
    sign.addFileArg(key);
    if (keyStep) |step| sign.step.dependOn(step);
    return apk;
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
    \\        android:label="{s}" android:debuggable="{}"
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
