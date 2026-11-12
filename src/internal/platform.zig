//! 平台实现选择与共用的适配逻辑。
const std = @import("std");
const builtin = @import("builtin");
const sk = @import("sokol");

const zhu = @import("../zhu.zig");
const codec = @import("codec.zig");

const Init = std.process.Init;
const Io = std.Io;
const assert = std.debug.assert;
const print = zhu.format;

var io: Io = undefined;

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

/// 读取原生资源文件；Android 使用 APK 资源，其他平台使用传入目录。
/// 返回的缓冲区由调用者释放，Web 不支持同步文件读取。
pub fn readFile(gpa: zhu.Allocator, dir: ?Io.Dir, path: [:0]const u8) ![]u8 {
    if (builtin.os.tag == .emscripten) @panic("web has no file system");
    if (builtin.abi.isAndroid()) return backend.readAsset(path, gpa);
    const file = try dir.?.openFile(io, path, .{});
    defer file.close(io);
    const size: usize = @intCast(try file.length(io));
    const data = try gpa.alloc(u8, size);
    errdefer gpa.free(data);
    if (try file.readPositionalAll(io, data, 0) != size) {
        return error.UnexpectedEof;
    }
    return data;
}

/// 用户数据存储，目录按应用区分，由 zhu.setup 的 storage 选项初始化。
pub const storage = struct {
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Allocator = std.mem.Allocator;
    const ArenaAllocator = std.heap.ArenaAllocator;

    var gpa: Allocator = undefined;
    // 初始化时复制路径，避免保存启动环境变量中的借用切片。
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dataPath: []const u8 = "";

    fn openOrCreateDir(create: bool) !std.Io.Dir {
        if (dataPath.len == 0) @panic("set a storage name in zhu.setup");
        if (create) return std.Io.Dir.cwd().createDirPathOpen(io, dataPath, .{});
        return std.Io.Dir.openDirAbsolute(io, dataPath, .{});
    }

    /// 检查用户数据文件是否存在，路径相对于存储目录。
    pub fn exists(path: [:0]const u8) bool {
        if (builtin.os.tag == .emscripten) return backend.storage.exists(path);
        const dir = openOrCreateDir(false) catch return false;
        defer dir.close(io);
        dir.access(io, path, .{}) catch return false;
        return true;
    }

    /// 读取用户数据，并在缓冲区末尾添加零字节。
    pub fn readBuffer(path: [:0]const u8, buffer: []u8) ![:0]u8 {
        if (builtin.os.tag == .emscripten)
            return backend.storage.readBuffer(path, buffer);
        const buf = buffer[0 .. buffer.len - 1];
        const dir = try openOrCreateDir(false);
        defer dir.close(io);
        const content = try dir.readFile(io, path, buf);
        return terminateBuffer(buffer, content.len);
    }

    /// 读取完整用户数据，由调用者释放返回的内存。
    pub fn readAll(gpa_: Allocator, path: [:0]const u8) ![:0]u8 {
        if (builtin.os.tag == .emscripten) return backend.storage.readAll(gpa_, path);
        const dir = try openOrCreateDir(false);
        defer dir.close(io);
        return dir.readFileAllocOptions(io, path, gpa_, .unlimited, .of(u8), 0);
    }

    /// 原子替换用户数据，首次写入时创建存储目录和文件所在的子目录。
    pub fn writeAll(path: [:0]const u8, content: []const u8) !void {
        if (builtin.os.tag == .emscripten)
            return backend.storage.writeAll(path, content);
        const dir = try openOrCreateDir(true);
        defer dir.close(io);
        var atomicFile = try dir.createFileAtomic(io, path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomicFile.deinit(io);
        try atomicFile.file.writeStreamingAll(io, content);
        try atomicFile.replace(io);
    }

    /// 读取结果拥有所有切片数据，使用结束后调用 deinit，切片随之失效。
    /// 读取的 ArrayList 由 arena 管理，扩容时应使用 arena 的分配器。
    pub fn Loaded(comptime T: type) type {
        return struct {
            value: T,
            arena: *ArenaAllocator,

            pub fn deinit(self: @This()) void {
                const gpa_ = self.arena.child_allocator;
                self.arena.deinit();
                gpa_.destroy(self.arena);
            }
        };
    }

    /// 按指定类型读取二进制存档，字段顺序和类型必须与写入时一致。
    pub fn readValue(comptime T: type, path: [:0]const u8) !Loaded(T) {
        const content = try readAll(gpa, path);
        defer gpa.free(content);

        const arena = try gpa.create(ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        var reader = Reader.fixed(content);
        const value = try codec.decode(&reader, T, arena.allocator());
        if (reader.seek != content.len) return error.InvalidData;
        return .{ .value = value, .arena = arena };
    }

    /// 按字段保存二进制数据，数值使用小端序，切片先写入 u64 长度。
    /// 支持 void、数值、布尔、枚举、可选值、数组、向量、结构体、带标签联合和切片。
    /// ArrayList 只保存元素，读取后容量等于元素数量。
    pub fn writeValue(path: [:0]const u8, value: anytype) !void {
        if (dataPath.len == 0) @panic("set a storage name in zhu.setup");
        var output = Writer.Allocating.init(gpa);
        defer output.deinit();
        try codec.encode(&output.writer, value);
        try writeAll(path, output.writer.buffered());
    }

    /// 带版本的存档，持有文件内容和读取时分配的数据。
    pub const Save = struct {
        version: u32,
        content: []const u8,
        arena: *ArenaAllocator,

        /// 每次从数据区开头读取，返回值中的切片在 deinit 后失效。
        /// 读取的 ArrayList 由 arena 管理，扩容时应使用 arena 的分配器。
        pub fn read(self: *Save, comptime T: type) !T {
            var reader = Reader.fixed(self.content);
            const value = try codec.decode(&reader, T, self.arena.allocator());
            if (reader.seek != self.content.len) return error.InvalidData;
            return value;
        }

        pub fn deinit(self: Save) void {
            const gpa_ = self.arena.child_allocator;
            self.arena.deinit();
            gpa_.destroy(self.arena);
        }
    };

    /// 打开带版本的存档，只解析文件头，由游戏按版本选择读取类型。
    pub fn openSave(path: [:0]const u8) !Save {
        if (dataPath.len == 0) @panic("set a storage name in zhu.setup");
        const arena = try gpa.create(ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const content = try readAll(arena.allocator(), path);
        var reader = Reader.fixed(content);
        const version = try codec.readVersion(&reader);
        return .{
            .version = version,
            .content = content[reader.seek..],
            .arena = arena,
        };
    }

    /// 保存带版本的数据，文件头为 ZHYU 标识和 u32 小端版本号。
    pub fn writeSave(path: [:0]const u8, version: u32, value: anytype) !void {
        if (dataPath.len == 0) @panic("set a storage name in zhu.setup");
        var output = Writer.Allocating.init(gpa);
        defer output.deinit();
        try codec.encodeVersion(&output.writer, version, value);
        try writeAll(path, output.writer.buffered());
    }

    // 为读取结果补上零字节，返回的切片仍由原缓冲区持有。
    fn terminateBuffer(buffer: []u8, len: usize) [:0]u8 {
        buffer[len] = 0;
        return buffer[0..len :0];
    }
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
/// 保存共用 IO，并按应用名称初始化用户数据存储。
pub fn setup(info: Init, gpa: zhu.Allocator, dir: ?[]const u8) void {
    io = info.io;
    backend.setup(gpa);
    if (dir) |name| {
        storage.gpa = gpa;
        storage.dataPath = if (builtin.os.tag == .emscripten)
            backend.storage.setup(name)
        else
            backend.storagePath(info, name, &storage.pathBuffer);
    }
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
