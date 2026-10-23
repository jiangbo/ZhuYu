const std = @import("std");
const Build = std.Build;

// iOS 应用标识、显示名称和屏幕方向。
pub const AppConfig = struct {
    bundleId: []const u8,
    label: []const u8,
    icon: ?Build.LazyPath = null, // 提供时复制为应用图标。
    orientation: enum { landscape, portrait, unspecified } = .landscape,
};

// 可执行文件与资源组成 .app，签名独立于本机交叉编译和打包。
pub const Options = struct {
    exe: *Build.Step.Compile,
    assets: []const u8 = "assets", // 相对于游戏项目的资源目录。
    versionCode: u32 = 1,
    versionName: []const u8 = "0.1.0",
    app: AppConfig,
};

// 注册 app 命令，直接用 Zig 生成目录，不依赖 Xcode 工程。
pub fn addStep(b: *Build, options: Options) void {
    const target = options.exe.rootModuleTarget();
    std.debug.assert(target.os.tag == .ios);
    const minimum = target.os.version_range.semver.min;
    const app = options.app;
    const files = b.addWriteFiles();
    _ = files.addCopyFile(options.exe.getEmittedBin(), options.exe.name);
    _ = files.addCopyDirectory(b.path(options.assets), "assets", .{});
    if (app.icon) |icon| _ = files.addCopyFile(icon, "Icon.png");

    // 最低版本取自编译目标，SDK 版本和流水线环境不改变此值。
    _ = files.add("Info.plist", b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleIdentifier</key><string>{s}</string>
        \\    <key>CFBundleDisplayName</key><string>{s}</string>
        \\    <key>CFBundleExecutable</key><string>{s}</string>
        \\    <key>CFBundleVersion</key><string>{d}</string>
        \\    <key>CFBundleShortVersionString</key><string>{s}</string>
        \\    <key>MinimumOSVersion</key><string>{d}.{d}.{d}</string>
        \\    <key>CFBundleSupportedPlatforms</key>
        \\    <array><string>{s}</string></array>
        \\    <key>CFBundleName</key><string>{s}</string>
        \\    <key>CFBundlePackageType</key><string>APPL</string>
        \\    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\    <key>LSRequiresIPhoneOS</key><true/>
        \\    <key>UIDeviceFamily</key>
        \\    <array><integer>1</integer><integer>2</integer></array>
        \\    <key>UIRequiredDeviceCapabilities</key>
        \\    <array><string>metal</string></array>
        \\    <key>UISupportedInterfaceOrientations</key>
        \\    <array>{s}</array>
        \\    <key>UIRequiresFullScreen</key><true/>
        \\    <key>UIStatusBarHidden</key><true/>
        \\    <key>UIViewControllerBasedStatusBarAppearance</key><false/>
        \\    <key>UILaunchScreen</key><dict/>
        \\    <key>CADisableMinimumFrameDurationOnPhone</key><true/>
        \\    <key>UIApplicationSceneManifest</key>
        \\    <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
        \\    {s}
        \\</dict>
        \\</plist>
        \\
    , .{
        app.bundleId,
        app.label,
        options.exe.name,
        options.versionCode,
        options.versionName,
        minimum.major,
        minimum.minor,
        minimum.patch,
        if (target.abi == .simulator) "iPhoneSimulator" else "iPhoneOS",
        app.label,
        switch (app.orientation) {
            .landscape =>
            \\<string>UIInterfaceOrientationLandscapeLeft</string>
            \\<string>UIInterfaceOrientationLandscapeRight</string>
            ,
            .portrait => "<string>UIInterfaceOrientationPortrait</string>",
            .unspecified =>
            \\<string>UIInterfaceOrientationPortrait</string>
            \\<string>UIInterfaceOrientationPortraitUpsideDown</string>
            \\<string>UIInterfaceOrientationLandscapeLeft</string>
            \\<string>UIInterfaceOrientationLandscapeRight</string>
            ,
        },
        if (app.icon != null)
            "<key>CFBundleIconFiles</key><array><string>Icon.png</string></array>"
        else
            "",
    }));
    const install = b.addInstallDirectory(.{
        .source_dir = files.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = b.fmt("app/{s}.app", .{options.exe.name}),
    });
    b.step("app", "Build an iOS app bundle").dependOn(&install.step);
}
