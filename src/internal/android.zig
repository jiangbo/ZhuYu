const std = @import("std");
const root = @import("root");
const sk = @import("sokol");
const dynamic = @import("../text.zig").dynamic;
const memory = @import("memory.zig");

// JNI 固定槽位，只声明本模块调用的方法，其余位置保留指针大小。
const Jni = extern struct {
    beforeFindClass: [6]?*anyopaque,
    FindClass: *const fn (*Env, [*:0]const u8) callconv(.c) ?*anyopaque,
    beforeExceptionDescribe: [9]?*anyopaque,
    ExceptionDescribe: *const fn (*Env) callconv(.c) void,
    ExceptionClear: *const fn (*Env) callconv(.c) void,
    beforePushLocalFrame: [1]?*anyopaque,
    PushLocalFrame: *const fn (*Env, c_int) callconv(.c) c_int,
    PopLocalFrame: *const fn (*Env, ?*anyopaque) callconv(.c) ?*anyopaque,
    NewGlobalRef: *const fn (*Env, ?*anyopaque) callconv(.c) ?*anyopaque,
    DeleteGlobalRef: *const fn (*Env, ?*anyopaque) callconv(.c) void,
    DeleteLocalRef: *const fn (*Env, ?*anyopaque) callconv(.c) void,
    beforeNewObjectA: [6]?*anyopaque,
    NewObjectA: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
        ?[*]const Value,
    ) callconv(.c) ?*anyopaque,
    GetObjectClass: *const fn (*Env, ?*anyopaque) callconv(.c) ?*anyopaque,
    beforeGetMethodID: [1]?*anyopaque,
    GetMethodID: *const fn (
        *Env,
        ?*anyopaque,
        [*:0]const u8,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque,
    beforeCallObjectMethodA: [2]?*anyopaque,
    CallObjectMethodA: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
        ?[*]const Value,
    ) callconv(.c) ?*anyopaque,
    beforeCallIntMethodA: [14]?*anyopaque,
    CallIntMethodA: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
        ?[*]const Value,
    ) callconv(.c) c_int,
    beforeCallFloatMethodA: [5]?*anyopaque,
    CallFloatMethodA: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
        ?[*]const Value,
    ) callconv(.c) f32,
    beforeCallVoidMethodA: [5]?*anyopaque,
    CallVoidMethodA: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
        ?[*]const Value,
    ) callconv(.c) void,
    beforeGetFieldID: [30]?*anyopaque,
    GetFieldID: *const fn (
        *Env,
        ?*anyopaque,
        [*:0]const u8,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque,
    beforeGetIntField: [5]?*anyopaque,
    GetIntField: *const fn (*Env, ?*anyopaque, *anyopaque) callconv(.c) c_int,
    beforeGetFloatField: [1]?*anyopaque,
    GetFloatField: *const fn (*Env, ?*anyopaque, *anyopaque) callconv(.c) f32,
    beforeGetStaticMethodID: [10]?*anyopaque,
    GetStaticMethodID: *const fn (
        *Env,
        ?*anyopaque,
        [*:0]const u8,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque,
    beforeCallStaticObjectMethodA: [2]?*anyopaque,
    CallStaticObjectMethodA: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
        ?[*]const Value,
    ) callconv(.c) ?*anyopaque,
    beforeGetStaticFieldID: [27]?*anyopaque,
    GetStaticFieldID: *const fn (
        *Env,
        ?*anyopaque,
        [*:0]const u8,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque,
    GetStaticObjectField: *const fn (
        *Env,
        ?*anyopaque,
        *anyopaque,
    ) callconv(.c) ?*anyopaque,
    beforeNewString: [17]?*anyopaque,
    NewString: *const fn (*Env, [*]const u16, c_int) callconv(.c) ?*anyopaque,
    GetStringLength: *const fn (*Env, ?*anyopaque) callconv(.c) c_int,
    GetStringChars: *const fn (
        *Env,
        ?*anyopaque,
        ?*u8,
    ) callconv(.c) ?[*]const u16,
    ReleaseStringChars: *const fn (
        *Env,
        ?*anyopaque,
        [*]const u16,
    ) callconv(.c) void,
    beforeExceptionCheck: [61]?*anyopaque,
    ExceptionCheck: *const fn (*Env) callconv(.c) u8,
    NewDirectByteBuffer: *const fn (*Env, [*]u8, i64) callconv(.c) ?*anyopaque,
};

// JNIEnv 是函数表指针，NDK 向应用提供它的地址。
const Env = *const Jni;

// JNI 参数共用 jvalue 布局，jlong 保持大小和对齐。
const Value = extern union {
    int: c_int,
    long: i64,
    float: f32,
    object: ?*anyopaque,
};

// 只访问焦点回调，保留它之前的六个生命周期回调槽位。
const Callbacks = extern struct {
    beforeFocus: [6]?*anyopaque,
    onWindowFocusChanged: *const fn (*Activity, c_int) callconv(.c) void,
};

// 对应 NDK android/native_activity.h，保持完整字段顺序和 C 内存布局。
const Activity = extern struct {
    callbacks: *Callbacks,
    vm: ?*anyopaque,
    env: *Env,
    clazz: ?*anyopaque,
    internalDataPath: [*:0]const u8,
    externalDataPath: ?[*:0]const u8,
    sdkVersion: i32,
    instance: ?*anyopaque,
    assetManager: ?*anyopaque,
    obbPath: ?[*:0]const u8,
};

extern fn ANativeActivity_onCreate(*Activity, ?*anyopaque, usize) void;

// 保存 Sokol 的焦点回调，系统 UI 操作仍在 Android UI 线程执行。
var focus: *const fn (*Activity, c_int) callconv(.c) void = undefined;

// 保留兼容旧系统的沉浸式全屏调用，不提高最低 Android 版本。
fn fullScreen(activity: *Activity) void {
    const env = activity.env;
    const jni = env.*;
    var class = jni.GetObjectClass(env, activity.clazz).?;
    var method = jni.GetMethodID(env, class, "getWindow", "()Landroid/view/Window;").?;
    const window = jni.CallObjectMethodA(env, activity.clazz, method, null).?;
    jni.DeleteLocalRef(env, class);

    class = jni.GetObjectClass(env, window).?;
    method = jni.GetMethodID(env, class, "getDecorView", "()Landroid/view/View;").?;
    const view = jni.CallObjectMethodA(env, window, method, null).?;
    jni.DeleteLocalRef(env, class);
    jni.DeleteLocalRef(env, window);

    class = jni.GetObjectClass(env, view).?;
    method = jni.GetMethodID(env, class, "setSystemUiVisibility", "(I)V").?;
    // 沿用沉浸式全屏与布局标志，调用参数使用数组而非 C 可变参数。
    jni.CallVoidMethodA(env, view, method, &.{.{ .int = 0x1706 }});
    jni.DeleteLocalRef(env, class);
    jni.DeleteLocalRef(env, view);
}

// 先转交 Sokol，再恢复沉浸式全屏。
fn onFocus(activity: *Activity, hasFocus: c_int) callconv(.c) void {
    focus(activity, hasFocus);
    if (hasFocus != 0) fullScreen(activity);
}

// APK 的 NativeActivity 入口，线程、窗口和输入仍由 Sokol 管理。
export fn zhuyu_main(activity: *Activity, state: ?*anyopaque, size: usize) void {
    ANativeActivity_onCreate(activity, state, size);
    focus = activity.callbacks.onWindowFocusChanged;
    activity.callbacks.onWindowFocusChanged = onFocus;
    fullScreen(activity);
}

// 游戏回调继续使用 IO，窗口配置由 window.run 写入后返回给 Sokol。
pub var threaded: std.Io.Threaded = undefined;
pub var desc: ?sk.app.Desc = null;

// NDK 管理的不透明配置对象。
const Configuration = opaque {};

extern fn AConfiguration_new() *Configuration;
extern fn AConfiguration_delete(*Configuration) void;
extern fn AConfiguration_fromAssetManager(*Configuration, ?*anyopaque) void;
extern fn AConfiguration_getDensity(*Configuration) i32;

// 从安卓配置读取界面密度，1 表示每个界面单位对应一个窗口像素。
pub fn density() f32 {
    const activity: *const Activity =
        @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
    const config = AConfiguration_new();
    defer AConfiguration_delete(config);
    AConfiguration_fromAssetManager(config, activity.assetManager);
    const value = AConfiguration_getDensity(config);
    return @as(f32, @floatFromInt(value)) / 160.0;
}

extern fn AAssetManager_open(?*anyopaque, [*:0]const u8, c_int) ?*anyopaque;
extern fn AAsset_getLength64(*anyopaque) i64;
extern fn AAsset_read(*anyopaque, [*]u8, usize) c_int;
extern fn AAsset_close(*anyopaque) void;

// 后台打开 APK 资源，按实际长度分配并读取。
pub fn readAsset(path: [:0]const u8, allocator: std.mem.Allocator) ![]u8 {
    const activity: *const Activity =
        @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
    const asset = AAssetManager_open(activity.assetManager, path, 2) orelse
        return error.FileNotFound;
    defer AAsset_close(asset);
    const size: usize = @intCast(AAsset_getLength64(asset));
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data[offset..];
        const count = AAsset_read(asset, remaining.ptr, remaining.len);
        if (count < 0) return error.ReadFailed;
        if (count == 0) return error.UnexpectedEof;
        offset += @intCast(count);
    }
    return data;
}

// 返回系统给出的私有目录绝对路径，路径在进程内一直有效。
pub fn dataPath() []const u8 {
    const activity: *const Activity =
        @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
    return std.mem.span(activity.internalDataPath);
}

// 初始化安卓运行环境，再调用游戏入口取得窗口配置。
export fn sokol_main(_: c_int, _: ?*?[*:0]u8) sk.app.Desc {
    const gpa = std.heap.c_allocator;
    threaded = .init(gpa, .{});

    // 只供 main 初始化阶段使用。
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const result = root.main(.{
        .minimal = .{
            .args = .{ .vector = &.{} },
            .environ = .empty,
        },
        .arena = &arena,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    });
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        _ = result catch |e| std.debug.panic("android main: {}", .{e});
    }
    return desc orelse @panic("android main must call window.run()");
}

extern fn __android_log_write(
    priority: c_int,
    tag: [*:0]const u8,
    text: [*:0]const u8,
) c_int;

extern fn __android_log_assert(
    condition: ?[*:0]const u8, // 传 null，直接使用格式化消息。
    tag: [*:0]const u8,
    format: [*:0]const u8,
    ...,
) noreturn;

// 将标准库日志直接写入 Logcat，只保留等级和消息。
pub fn log(
    comptime level: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = comptime level.asText() ++ ": ";
    // 对应 Android 的 ERROR、WARN、INFO、DEBUG 等级。
    const priority: c_int = switch (level) {
        .err => 6,
        .warn => 5,
        .info => 4,
        .debug => 3,
    };
    var buffer: [4000]u8 = undefined;
    const message = std.mem.printSentinel(&buffer, //
        prefix ++ format, args, 0) catch {
        const suffix = "...[truncated]";
        @memcpy(buffer[buffer.len - suffix.len - 1 ..][0..suffix.len], suffix);
        buffer[buffer.len - 1] = 0;
        _ = __android_log_write(priority, "ZhuYu", @ptrCast(&buffer));
        return;
    };
    _ = __android_log_write(priority, "ZhuYu", message);
}

// 显式 panic 和 Zig 安全检查统一使用安卓的崩溃输出。
pub const panic = std.debug.FullPanic(panicMessage);

fn panicMessage(message: []const u8, _: ?usize) noreturn {
    __android_log_assert(
        null,
        "ZhuYu",
        "panic: %.*s",
        @as(c_int, @intCast(message.len)),
        message.ptr,
    );
}

// Android 系统字体和平台入口共用 JNI 声明。
pub const font = struct {
    // JavaVM 可以跨线程使用，JNIEnv 只在所属线程内使用。
    const Vm = *const extern struct {
        beforeAttach: [4]?*anyopaque,
        AttachCurrentThread: *const fn (*Vm, *?*Env, ?*anyopaque) callconv(.c) c_int,
        DetachCurrentThread: *const fn (*Vm) callconv(.c) c_int,
        GetEnv: *const fn (*Vm, *?*Env, c_int) callconv(.c) c_int,
    };

    var vm: *Vm = undefined; // 当前 NativeActivity 所属的 JavaVM。
    var attached: bool = false; // 只解除本后端建立的线程关联。
    var paint: *anyopaque = undefined; // 持有字体、字号、字重及中文语言设置。
    var bounds: *anyopaque = undefined; // 每个字形复用的整数边界对象。
    var metrics: *anyopaque = undefined; // 字号变化时复用的字体度量对象。
    var bitmapClass: *anyopaque = undefined; // 扩容时调用静态工厂需要的类引用。
    var config: *anyopaque = undefined; // ALPHA_8 配置，只存覆盖率。
    var bitmap: ?*anyopaque = null; // 容量不足时替换的系统位图。
    var canvas: ?*anyopaque = null; // 与当前位图绑定的离屏画布。
    var bitmapWidth: c_int = 0; // 当前位图宽度，包含透明边框。
    var bitmapHeight: c_int = 0; // 当前位图高度，包含透明边框。
    var rowBytes: usize = 0; // 系统位图实际行跨度，可能含对齐字节。
    var alpha: []u8 = &.{}; // 接收位图覆盖率的复用缓冲区。

    // 方法及字段 ID 在初始化时查找，生成字形时直接调用。
    var setSize: *anyopaque = undefined;
    var getMetrics: *anyopaque = undefined;
    var getBounds: *anyopaque = undefined;
    var measureText: *anyopaque = undefined;
    var createBitmap: *anyopaque = undefined;
    var canvasClass: *anyopaque = undefined;
    var canvasInit: *anyopaque = undefined;
    var eraseColor: *anyopaque = undefined;
    var drawText: *anyopaque = undefined;
    var copyPixels: *anyopaque = undefined;
    var getRowBytes: *anyopaque = undefined;
    var boundFields: [4]*anyopaque = undefined; // left、top、right、bottom。
    var metricFields: [3]*anyopaque = undefined; // ascent、descent、leading。

    // 打开系统字体，在游戏线程取得 JNI 环境，所有持久对象使用全局引用。
    // 返回写入的名称字节数，旧系统无法查询时返回零。
    pub fn open(option: dynamic.Option, nameBuffer: []u8) usize {
        const activity: *const Activity =
            @ptrCast(@alignCast(sk.app.androidGetNativeActivity().?));
        vm = @ptrCast(@alignCast(activity.vm.?));
        var env: ?*Env = null;
        // JNI 1.6 的版本编号，未关联的线程返回 JNI_EDETACHED（-2）。
        const status = vm.*.GetEnv(vm, &env, 0x00010006);
        attached = status == -2;
        if (attached) {
            if (vm.*.AttachCurrentThread(vm, &env, null) != 0)
                @panic("font JNI thread attach failed");
        } else if (status != 0) @panic("font JNI unavailable");
        const e = env.?;
        begin(e);
        defer end(e);
        const jni = e.*;

        const paintClass = class(e, "android/graphics/Paint");
        const rectClass = class(e, "android/graphics/Rect");
        const metricsClass = class(e, "android/graphics/Paint$FontMetrics");
        const typefaceClass = class(e, "android/graphics/Typeface");
        const localeClass = class(e, "java/util/Locale");
        bitmapClass = hold(e, class(e, "android/graphics/Bitmap"));
        canvasClass = hold(e, class(e, "android/graphics/Canvas"));
        const configClass = class(e, "android/graphics/Bitmap$Config");
        config = hold(e, staticObject(e, configClass, "ALPHA_8", //
            "Landroid/graphics/Bitmap$Config;"));

        // Paint 的第 0 位开启抗锯齿；采样过滤仍由公共字形图集控制。
        const paintInit = method(e, paintClass, "<init>", "(I)V");
        paint = hold(e, object(e, jni.NewObjectA(e, paintClass, //
            paintInit, &.{.{ .int = 1 }})));
        const rectInit = method(e, rectClass, "<init>", "()V");
        bounds = hold(e, object(e, jni.NewObjectA(e, rectClass, rectInit, null)));
        const metricsInit = method(e, metricsClass, "<init>", "()V");
        metrics = hold(e, object(e, jni.NewObjectA(e, metricsClass, //
            metricsInit, null)));

        // 字体名称使用标准 UTF-8 转 UTF-16，避免 JNI 修改版 UTF-8 的限制。
        const len = std.unicode.calcUtf16LeLen(option.family) catch
            @panic("font name is not valid UTF-8");
        var name: [1024]u16 = undefined; // JNI 按长度读取，不需要结尾零。
        if (len > name.len) @panic("font name exceeds 1024 UTF-16 units");
        _ = std.unicode.utf8ToUtf16Le(name[0..len], option.family) catch unreachable;
        const family = object(e, jni.NewString(e, &name, @intCast(len)));
        const create = object(e, jni.GetStaticMethodID(e, typefaceClass, "create", //
            "(Ljava/lang/String;I)Landroid/graphics/Typeface;"));
        const face = object(e, jni.CallStaticObjectMethodA(e, typefaceClass, //
            create, &.{
                .{ .object = family },
                .{ .int = if (option.weight == .bold) 1 else 0 },
            }));
        var nameLen: usize = 0; // 未取得名称时由公共层使用 family。
        // API 34 才公开系统字体族查询；旧系统清除方法查找异常。
        const getName = jni.GetMethodID(
            e,
            typefaceClass,
            "getSystemFontFamilyName",
            "()Ljava/lang/String;",
        );
        if (getName) |get| {
            if (jni.CallObjectMethodA(e, face, get, null)) |selected| {
                const count = jni.GetStringLength(e, selected);
                const chars = jni.GetStringChars(e, selected, null) orelse
                    memory.oom();
                defer jni.ReleaseStringChars(e, selected, chars);
                // 直接从 JNI 借用的 UTF-16 写入名称缓冲，不分配中间字符串。
                const selectedName = chars[0..@intCast(count)];
                if (std.unicode.calcWtf8Len(selectedName) <= nameBuffer.len) {
                    nameLen = std.unicode.utf16LeToUtf8(
                        nameBuffer,
                        selectedName,
                    ) catch @panic("invalid font name");
                }
            }
            check(e);
        } else {
            jni.ExceptionClear(e);
        }
        const setTypeface = method(e, paintClass, "setTypeface", //
            "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;");
        _ = jni.CallObjectMethodA(e, paint, setTypeface, &.{.{ .object = face }});
        check(e);
        const locale = staticObject(e, localeClass, "SIMPLIFIED_CHINESE", //
            "Ljava/util/Locale;");
        call(e, paint, method(e, paintClass, "setTextLocale", //
            "(Ljava/util/Locale;)V"), &.{.{ .object = locale }});
        call(e, paint, method(e, paintClass, "setColor", "(I)V"), &.{.{ .int = -1 }});

        setSize = method(e, paintClass, "setTextSize", "(F)V");
        getMetrics = method(e, paintClass, "getFontMetrics", //
            "(Landroid/graphics/Paint$FontMetrics;)F");
        getBounds = method(e, paintClass, "getTextBounds", //
            "(Ljava/lang/String;IILandroid/graphics/Rect;)V");
        measureText = method(e, paintClass, "measureText", "(Ljava/lang/String;)F");
        createBitmap = object(e, jni.GetStaticMethodID(e, bitmapClass, //
            "createBitmap", //
            "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;"));
        canvasInit = method(e, canvasClass, "<init>", "(Landroid/graphics/Bitmap;)V");
        eraseColor = method(e, bitmapClass, "eraseColor", "(I)V");
        drawText = method(e, canvasClass, "drawText", //
            "(Ljava/lang/String;FFLandroid/graphics/Paint;)V");
        copyPixels = method(e, bitmapClass, "copyPixelsToBuffer", //
            "(Ljava/nio/Buffer;)V");
        getRowBytes = method(e, bitmapClass, "getRowBytes", "()I");
        for ([_][*:0]const u8{ "left", "top", "right", "bottom" }, 0..) |key, i| {
            boundFields[i] = object(e, jni.GetFieldID(e, rectClass, key, "I"));
        }
        for ([_][*:0]const u8{ "ascent", "descent", "leading" }, 0..) |key, i| {
            metricFields[i] = object(e, jni.GetFieldID(e, metricsClass, key, "F"));
        }
        return nameLen;
    }

    // Android 的 ascent 为负，公共层统一使用正的基线上方距离。
    pub fn resize(size: f32) dynamic.Metrics {
        const e = environment();
        call(e, paint, setSize, &.{.{ .float = size }});
        const height = e.*.CallFloatMethodA(e, paint, //
            getMetrics, &.{.{ .object = metrics }});
        check(e);
        const ascent = e.*.GetFloatField(e, metrics, metricFields[0]);
        const descent = e.*.GetFloatField(e, metrics, metricFields[1]);
        const leading = e.*.GetFloatField(e, metrics, metricFields[2]);
        check(e);
        return .{
            .ascent = -ascent,
            .descent = descent,
            .height = @max(size, @max(height, descent - ascent + leading)),
        };
    }

    // 单个码位编码成 UTF-16，位图覆盖率转换为白色 RGBA。
    pub fn pixels(code: u32, buffer: []u8) dynamic.Char {
        const e = environment();
        begin(e);
        defer end(e);
        const jni = e.*;
        var utf16: [2]u16 = undefined;
        var count: c_int = 1;
        if (code <= 0xffff) {
            utf16[0] = @intCast(code);
        } else {
            utf16[0] = @intCast(0xd800 + ((code - 0x10000) >> 10));
            utf16[1] = @intCast(0xdc00 + ((code - 0x10000) & 0x3ff));
            count = 2;
        }
        const text = object(e, jni.NewString(e, &utf16, count));
        call(e, paint, getBounds, &.{
            .{ .object = text }, .{ .int = 0 },
            .{ .int = count },   .{ .object = bounds },
        });
        const left = jni.GetIntField(e, bounds, boundFields[0]);
        const top = jni.GetIntField(e, bounds, boundFields[1]);
        const width = jni.GetIntField(e, bounds, boundFields[2]) - left;
        const height = jni.GetIntField(e, bounds, boundFields[3]) - top;
        const advance = jni.CallFloatMethodA(e, paint, //
            measureText, &.{.{ .object = text }});
        check(e);
        const char = dynamic.Char{
            .rect = .{
                .min = .xy(@floatFromInt(left), @floatFromInt(top)),
                .size = .xy(@floatFromInt(width), @floatFromInt(height)),
            },
            .advance = advance,
        };
        if (width == 0 or height == 0) return char;
        const stride: usize = @intCast((width + 2) * 4);
        const len = stride * @as(usize, @intCast(height + 2));
        if (buffer.len < len) return char;
        grow(e, width + 2, height + 2);
        call(e, bitmap.?, eraseColor, &.{.{ .int = 0 }});
        call(e, canvas.?, drawText, &.{
            .{ .object = text },
            .{ .float = @floatFromInt(1 - left) },
            .{ .float = @floatFromInt(1 - top) },
            .{ .object = paint },
        });
        const bytes = object(e, jni.NewDirectByteBuffer(e, alpha.ptr, //
            @intCast(rowBytes * @as(usize, @intCast(bitmapHeight)))));
        call(e, bitmap.?, copyPixels, &.{.{ .object = bytes }});
        @memset(buffer[0..len], 0);
        for (0..@as(usize, @intCast(height))) |y| {
            for (0..@as(usize, @intCast(width))) |x| {
                const offset = (y + 1) * stride + (x + 1) * 4;
                @memset(buffer[offset..][0..3], 255);
                buffer[offset + 3] = alpha[(y + 1) * rowBytes + x + 1];
            }
        }
        return char;
    }

    // 位图和画布只在容量不足时替换，读回时遵循系统返回的行跨度。
    fn grow(e: *Env, width: c_int, height: c_int) void {
        if (width <= bitmapWidth and height <= bitmapHeight) return;
        const jni = e.*;
        if (canvas) |value| jni.DeleteGlobalRef(e, value);
        if (bitmap) |value| jni.DeleteGlobalRef(e, value);
        bitmapWidth = @max(width, bitmapWidth);
        bitmapHeight = @max(height, bitmapHeight);
        bitmap = hold(e, object(e, jni.CallStaticObjectMethodA(e, bitmapClass, //
            createBitmap, &.{
                .{ .int = bitmapWidth }, .{ .int = bitmapHeight },
                .{ .object = config },
            })));
        canvas = hold(e, object(e, jni.NewObjectA(e, canvasClass, //
            canvasInit, &.{.{ .object = bitmap }})));
        const stride = jni.CallIntMethodA(e, bitmap, getRowBytes, null);
        check(e);
        rowBytes = @intCast(stride);
        const len = rowBytes * @as(usize, @intCast(bitmapHeight));
        if (alpha.len < len)
            alpha = memory.allocator.realloc(alpha, len) catch memory.oom();
    }

    // 释放所有全局引用及缓冲区，再按需解除线程关联。
    pub fn close() void {
        const e = environment();
        const jni = e.*;
        if (canvas) |value| jni.DeleteGlobalRef(e, value);
        if (bitmap) |value| jni.DeleteGlobalRef(e, value);
        for ([_]*anyopaque{
            paint, bounds, metrics, bitmapClass, canvasClass, config,
        }) |value| jni.DeleteGlobalRef(e, value);
        canvas = null;
        bitmap = null;
        bitmapWidth = 0;
        bitmapHeight = 0;
        rowBytes = 0;
        memory.allocator.free(alpha);
        alpha = &.{};
        if (attached) {
            if (vm.*.DetachCurrentThread(vm) != 0)
                @panic("font JNI thread detach failed");
            attached = false;
        }
    }

    // 每次取得当前线程的环境，避免误用 Activity 的 UI 线程环境。
    fn environment() *Env {
        var env: ?*Env = null;
        if (vm.*.GetEnv(vm, &env, 0x00010006) != 0)
            @panic("font JNI thread unavailable");
        return env.?;
    }

    // 原生线程不会自动清理局部引用，每次生成字形建立独立引用帧。
    fn begin(e: *Env) void {
        if (e.*.PushLocalFrame(e, 32) != 0) fail(e);
    }

    // 退出引用帧时释放本次调用创建的全部局部引用。
    fn end(e: *Env) void {
        _ = e.*.PopLocalFrame(e, null);
    }

    // 系统异常输出到 Logcat 后终止，避免带着未处理异常继续调用 JNI。
    fn check(e: *Env) void {
        if (e.*.ExceptionCheck(e) != 0) fail(e);
    }

    // 保留 Java 异常堆栈，再进入引擎的统一 panic 日志。
    fn fail(e: *Env) noreturn {
        e.*.ExceptionDescribe(e);
        e.*.ExceptionClear(e);
        @panic("system font JNI call failed");
    }

    // 必须返回对象或 ID 的 JNI 调用统一检查空值与异常。
    fn object(e: *Env, value: ?*anyopaque) *anyopaque {
        check(e);
        return value orelse @panic("system font JNI object unavailable");
    }

    // 全局引用跨越本次调用，关闭时统一释放。
    fn hold(e: *Env, value: *anyopaque) *anyopaque {
        return object(e, e.*.NewGlobalRef(e, value));
    }

    // 仅查找 Android 自带的系统类，不需要应用的类加载器。
    fn class(e: *Env, name: [*:0]const u8) *anyopaque {
        return object(e, e.*.FindClass(e, name));
    }

    // 查找系统类的实例方法，签名与 Android 公开 API 一致。
    fn method(
        e: *Env,
        owner: *anyopaque,
        name: [*:0]const u8, //
        signature: [*:0]const u8,
    ) *anyopaque {
        return object(e, e.*.GetMethodID(e, owner, name, signature));
    }

    // 读取系统框架公开的单例对象，如中文语言和位图配置。
    fn staticObject(
        e: *Env,
        owner: *anyopaque,
        name: [*:0]const u8, //
        signature: [*:0]const u8,
    ) *anyopaque {
        const field = object(e, e.*.GetStaticFieldID(e, owner, name, signature));
        return object(e, e.*.GetStaticObjectField(e, owner, field));
    }

    // 所有实例 void 方法都在调用后立即检查 Java 异常。
    fn call(e: *Env, value: *anyopaque, id: *anyopaque, args: []const Value) void {
        e.*.CallVoidMethodA(e, value, id, args.ptr);
        check(e);
    }
};
