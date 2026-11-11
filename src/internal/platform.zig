//! 平台实现选择与共用的适配逻辑。
const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");
const assert = std.debug.assert;
const print = @import("../zhu.zig").format;

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

/// 日期时间格式的最大字节数，包含秒级 UTC 偏移，不含零结尾。
pub const dateTimeBufferSize = 32;

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

    /// YYYY-MM-DD HH:mm:ss，缓冲区不足时终止。
    pub fn format(self: DateTime, buf: []u8) []u8 {
        return self.formatDateTime(buf, ' ');
    }

    /// YYYY-MM-DD，缓冲区不足时终止。
    pub fn formatDate(self: DateTime, buf: []u8) []u8 {
        assert(self.year >= 0 and self.year <= 9999);
        const parts = .{ @abs(self.year), @abs(self.month), @abs(self.day) };
        return print(buf, "{d:0>4}-{d:0>2}-{d:0>2}", parts);
    }

    /// HH:mm:ss，缓冲区不足时终止。
    pub fn formatTime(self: DateTime, buf: []u8) []u8 {
        const parts = .{ @abs(self.hour), @abs(self.minute), @abs(self.second) };
        return print(buf, "{d:0>2}:{d:0>2}:{d:0>2}", parts);
    }

    /// ISO 8601 日期时间，带本地 UTC 偏移；UTC 使用 Z。
    pub fn formatIso(self: DateTime, buf: []u8) []u8 {
        const date = self.formatDateTime(buf, 'T');
        const tail = buf[date.len..];
        if (self.utcOffset == 0) {
            const zone = print(tail, "Z", .{});
            return buf[0 .. date.len + zone.len];
        }
        const offset = @abs(self.utcOffset);
        const sign: u8 = if (self.utcOffset < 0) '-' else '+';
        const parts = .{ sign, offset / 3600, offset % 3600 / 60 };
        const zone = print(tail, "{c}{d:0>2}:{d:0>2}", parts);
        var len = date.len + zone.len;
        if (offset % 60 != 0) {
            const seconds = print(buf[len..], ":{d:0>2}", .{offset % 60});
            len += seconds.len;
        }
        return buf[0..len];
    }

    fn formatDateTime(self: DateTime, buf: []u8, separator: u8) []u8 {
        assert(self.year >= 0 and self.year <= 9999);
        const date = "{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}";
        const parts = .{
            @abs(self.year), @abs(self.month),  @abs(self.day),    separator,
            @abs(self.hour), @abs(self.minute), @abs(self.second),
        };
        return print(buf, date, parts);
    }
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
