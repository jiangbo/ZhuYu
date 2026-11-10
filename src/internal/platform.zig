//! 平台实现选择与共用的适配逻辑。
const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const assert = std.debug.assert;

pub const backend = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .macos, .ios => @import("apple.zig"),
    .linux => if (builtin.abi.isAndroid())
        @import("android.zig")
    else
        @import("linux.zig"),
    .emscripten => @import("web.zig"),
    else => struct {},
};

/// 公历日期和本地时间。月份为 1～12，日期为 1～31。
/// utcOffset 是该时刻相对 UTC 的偏移秒数，东区为正，已包含夏令时。
pub const DateTime = extern struct {
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
    utcOffset: i32,
};

// POSIX 平台在启动时读取时区设置。
pub fn setup() void {
    switch (builtin.os.tag) {
        .linux, .macos, .ios => posixTime.tzset(),
        else => {},
    }
}

/// 使用本地时区转换指定时刻；需要先调用 zhu.setup。
/// 不主动刷新运行期间的时区设置。
/// 调用方保证日期在平台支持范围内，系统转换须成功。
pub fn localTime(value: std.Io.Timestamp) DateTime {
    // 向下取整，保证纪元前不足一秒的时间仍落在前一秒。
    const seconds: i64 = @intCast(@divFloor(value.nanoseconds, std.time.ns_per_s));
    return switch (builtin.os.tag) {
        .linux, .macos, .ios => posixTime.localTime(seconds),
        .windows => @import("windows.zig").localTime(seconds),
        .emscripten => @import("web.zig").localTime(seconds),
        else => @compileError("local time is not supported on this platform"),
    };
}

pub fn run(desc: sk.app.Desc, disableIME: bool) void {
    if (builtin.os.tag == .windows and disableIME) {
        _ = backend.ImmDisableIME(-1);
    }
    if (!builtin.abi.isAndroid()) return sk.app.run(desc);
    backend.desc = desc;
}

// 浏览器查询主要指针类型，移动平台默认推测没有实体键盘。
pub fn mayNotHaveKeyboard() bool {
    if (builtin.os.tag == .emscripten) return backend.zhu_coarse_pointer() != 0;
    return builtin.abi.isAndroid() or builtin.os.tag == .ios;
}

// Linux、Android 和 Apple 共用 POSIX 的本地时间接口。
const posixTime = struct {
    // Linux、Android 和 Apple 的 struct tm；尾部偏移使用各平台的 C long。
    const Tm = extern struct {
        second: c_int,
        minute: c_int,
        hour: c_int,
        day: c_int,
        month: c_int,
        year: c_int,
        weekDay: c_int,
        yearDay: c_int,
        isDst: c_int,
        offset: c_long,
        zone: ?[*:0]const u8,
    };

    extern "c" fn tzset() void;
    extern "c" fn localtime_r(*const std.c.time_t, *Tm) ?*Tm;
    extern "c" fn __localtime64_r(*const i64, *Tm) ?*Tm;

    fn localTime(seconds: i64) DateTime {
        var result: Tm = undefined;
        // 32 位 musl 的 time.h 将 localtime_r 重定向到 64 位时间接口。
        if (builtin.abi.isMusl() and @sizeOf(std.c.time_t) == 4) {
            assert(__localtime64_r(&seconds, &result) != null);
        } else {
            const value: std.c.time_t = @intCast(seconds);
            assert(localtime_r(&value, &result) != null);
        }
        return .{
            .year = result.year + 1900,
            .month = result.month + 1,
            .day = result.day,
            .hour = result.hour,
            .minute = result.minute,
            .second = result.second,
            .utcOffset = @intCast(result.offset),
        };
    }
};
