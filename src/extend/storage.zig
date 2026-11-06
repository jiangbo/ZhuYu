//! 用户数据存储，目录按应用区分，由游戏在启动阶段单独初始化。
const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../internal/memory.zig");
const android = @import("../internal/android.zig");
const web = @import("../internal/web.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

var io: std.Io = undefined;
// 初始化时复制路径，避免保存启动环境变量中的借用切片。
var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
var dataPath: []const u8 = undefined;

/// 在游戏 main 中调用；name 是固定的应用数据名称，用于桌面目录和 Web 存储键。
/// 安卓和 iOS 使用应用沙盒，Web 使用 name 作为浏览器存储键的前缀。
pub fn init(info: std.process.Init, name: []const u8) void {
    io = info.io;
    const env = info.environ_map;
    dataPath = switch (builtin.os.tag) {
        .windows => memory.format(&pathBuffer, "{s}\\{s}", .{
            env.get("APPDATA") orelse @panic("APPDATA not set"),
            name,
        }),
        .linux => if (builtin.abi.isAndroid())
            android.dataPath()
        else if (env.get("XDG_DATA_HOME")) |data|
            memory.format(&pathBuffer, "{s}/{s}", .{ data, name })
        else
            memory.format(&pathBuffer, "{s}/.local/share/{s}", .{
                env.get("HOME") orelse @panic("HOME not set"),
                name,
            }),
        .macos => memory.format(&pathBuffer, "{s}/{s}/{s}", .{
            env.get("HOME") orelse @panic("HOME not set"),
            "Library/Application Support",
            name,
        }),
        .ios => memory.format(&pathBuffer, "{s}/{s}", .{
            env.get("HOME") orelse @panic("HOME not set"),
            "Library/Application Support",
        }),
        .emscripten => memory.format(&pathBuffer, "{s}", .{name}),
        else => return,
    };
}

/// 检查用户数据文件是否存在，路径相对于存储目录。
pub fn exists(path: [:0]const u8) bool {
    if (builtin.os.tag == .emscripten) {
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return web.storage.exists(webKey(&keyBuffer, path));
    }
    const dir = std.Io.Dir.openDirAbsolute(io, dataPath, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// 读取用户数据，并在缓冲区末尾添加零字节。
pub fn readBuffer(path: [:0]const u8, buffer: []u8) ![:0]u8 {
    const buf = buffer[0 .. buffer.len - 1];
    if (builtin.os.tag == .emscripten) {
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return switch (try web.storage.load(webKey(&keyBuffer, path), buf)) {
            .loaded => |content| terminateBuffer(buffer, content.len),
            .tooSmall => error.BufferTooSmall,
        };
    }
    const dir = try std.Io.Dir.openDirAbsolute(io, dataPath, .{});
    defer dir.close(io);
    const content = try dir.readFile(io, path, buf);
    return terminateBuffer(buffer, content.len);
}

/// 读取完整用户数据，由调用者释放返回的内存。
pub fn readAll(gpa: Allocator, path: [:0]const u8) ![:0]u8 {
    if (builtin.os.tag == .emscripten) {
        var buffer: [4096]u8 = undefined;
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const key = webKey(&keyBuffer, path);
        return switch (try web.storage.load(key, &buffer)) {
            .loaded => |content| try gpa.dupeSentinel(u8, content, 0),
            .tooSmall => |len| readFromJs(gpa, path, len),
        };
    }
    const dir = try std.Io.Dir.openDirAbsolute(io, dataPath, .{});
    defer dir.close(io);
    return dir.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
}

/// 保存用户数据，首次写入时创建存储目录和文件所在的子目录。
pub fn writeAll(path: [:0]const u8, content: []const u8) !void {
    if (builtin.os.tag == .emscripten) {
        var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return web.storage.save(webKey(&keyBuffer, path), content);
    }
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, dataPath, .{});
    defer dir.close(io);
    if (std.fs.path.dirname(path)) |sub| try dir.createDirPath(io, sub);

    var file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// 读取结果拥有所有切片数据，使用结束后调用 deinit，切片随之失效。
pub fn Loaded(comptime T: type) type {
    return struct {
        value: T,
        arena: *ArenaAllocator,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

/// 按指定类型读取二进制存档，字段顺序和类型必须与写入时一致。
pub fn readValue(comptime T: type, path: [:0]const u8) !Loaded(T) {
    const gpa = memory.allocator;
    const content = try readAll(gpa, path);
    defer gpa.free(content);

    const arena = try gpa.create(ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var reader = Reader.fixed(content);
    const value = try decode(&reader, T, arena.allocator());
    if (reader.seek != content.len) return error.InvalidData;
    return .{ .value = value, .arena = arena };
}

/// 按字段保存二进制数据，数值使用小端序，切片先写入 u64 长度。
/// 支持 void、数值、布尔、枚举、可选值、数组、向量、结构体、带标签联合和切片。
pub fn writeValue(path: [:0]const u8, value: anytype) !void {
    var output = Writer.Allocating.init(memory.allocator);
    defer output.deinit();
    try encode(&output.writer, value);
    try writeAll(path, output.writer.buffered());
}

/// 带版本的存档，持有文件内容和读取时分配的数据。
pub const Save = struct {
    version: u32,
    content: []const u8,
    arena: *ArenaAllocator,

    /// 每次从数据区开头读取，返回值中的切片在 deinit 后失效。
    pub fn read(self: *Save, comptime T: type) !T {
        var reader = Reader.fixed(self.content);
        const value = try decode(&reader, T, self.arena.allocator());
        if (reader.seek != self.content.len) return error.InvalidData;
        return value;
    }

    pub fn deinit(self: Save) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

/// 打开带版本的存档，只解析文件头，由游戏按版本选择读取类型。
pub fn openSave(path: [:0]const u8) !Save {
    const gpa = memory.allocator;
    const arena = try gpa.create(ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const content = try readAll(arena.allocator(), path);
    var reader = Reader.fixed(content);
    if (!std.mem.eql(u8, try reader.take(4), "ZHYU")) return error.InvalidData;
    return .{
        .version = try reader.takeInt(u32, .little),
        .content = content[reader.seek..],
        .arena = arena,
    };
}

/// 保存带版本的数据，文件头为 ZHYU 标识和 u32 小端版本号。
pub fn writeSave(path: [:0]const u8, version: u32, value: anytype) !void {
    var output = Writer.Allocating.init(memory.allocator);
    defer output.deinit();
    try output.writer.writeAll("ZHYU");
    try output.writer.writeInt(u32, version, .little);
    try encode(&output.writer, value);
    try writeAll(path, output.writer.buffered());
}

fn encode(writer: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try writer.writeByte(@intFromBool(value)),
        .int => {
            const Int = switch (T) {
                usize => u64,
                isize => i64,
                else => std.math.ByteAlignedInt(T),
            };
            try writer.writeInt(Int, value, .little);
        },
        .float => {
            const Int = @Int(.unsigned, @bitSizeOf(T));
            try writer.writeInt(Int, @bitCast(value), .little);
        },
        .@"enum" => try encode(writer, @backingInt(value)),
        .optional => {
            try writer.writeByte(@intFromBool(value != null));
            if (value) |item| try encode(writer, item);
        },
        .array => for (value) |item| try encode(writer, item),
        .vector => |info| {
            const array: [info.len]info.child = value;
            try encode(writer, array);
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("expected a tagged union");
            try encode(writer, std.meta.activeTag(value));
            switch (value) {
                inline else => |item| try encode(writer, item),
            }
        },
        .@"struct" => |info| {
            inline for (info.field_names) |name| {
                try encode(writer, @field(value, name));
            }
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("expected a slice");
            try writer.writeInt(u64, value.len, .little);
            for (value) |item| try encode(writer, item);
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn decode(reader: *Reader, comptime T: type, gpa: Allocator) //
(Reader.Error || Allocator.Error || error{InvalidData})!T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => (try reader.takeByte()) != 0,
        .int => blk: {
            const Int = switch (T) {
                usize => u64,
                isize => i64,
                else => std.math.ByteAlignedInt(T),
            };
            const value = try reader.takeInt(Int, .little);
            break :blk std.math.cast(T, value) orelse return error.InvalidData;
        },
        .float => blk: {
            const Int = @Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(try reader.takeInt(Int, .little));
        },
        .@"enum" => |info| blk: {
            const value = try decode(reader, info.tag_type, gpa);
            break :blk std.enums.fromInt(T, value) orelse return error.InvalidData;
        },
        .optional => |info| if (try reader.takeByte() == 0)
            null
        else
            try decode(reader, info.child, gpa),
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decode(reader, info.child, gpa);
            if (comptime info.sentinel()) |sentinel| {
                result[info.len] = sentinel;
            }
            break :blk result;
        },
        .vector => |info| blk: {
            const array = try decode(reader, [info.len]info.child, gpa);
            break :blk array;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse @compileError("expected a tagged union");
            const tag = try decode(reader, Tag, gpa);
            inline for (info.field_names, info.field_types) |name, Field| {
                if (@field(Tag, name) == tag) {
                    const value = try decode(reader, Field, gpa);
                    break :blk @unionInit(T, name, value);
                }
            }
            return error.InvalidData;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| {
                @field(result, name) = try decode(reader, Field, gpa);
            }
            break :blk result;
        },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("expected a slice");
            const len = std.math.cast(usize, try reader.takeInt(u64, .little));
            const alignment = info.attrs.@"align" orelse @alignOf(info.child);
            const items = try gpa.allocWithOptions(
                info.child,
                len orelse return error.InvalidData,
                std.mem.Alignment.fromByteUnits(alignment),
                info.sentinel(),
            );
            for (items) |*item| item.* = try decode(reader, info.child, gpa);
            break :blk items;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    };
}

// 为读取结果补上零字节，返回的切片仍由原缓冲区持有。
fn terminateBuffer(buffer: []u8, len: usize) [:0]u8 {
    buffer[len] = 0;
    return buffer[0..len :0];
}

// 浏览器数据超过初始缓冲区时，按实际长度分配后重新读取。
fn readFromJs(gpa: Allocator, path: [:0]const u8, len: usize) ![:0]u8 {
    const large = try gpa.alloc(u8, len + 1);
    errdefer gpa.free(large);
    var keyBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const key = webKey(&keyBuffer, path);
    return switch (try web.storage.load(key, large[0..len])) {
        .loaded => |content| terminateBuffer(large, content.len),
        .tooSmall => error.BufferTooSmall,
    };
}

// 同一站点的不同游戏通过固定名称区分存档。
fn webKey(buffer: []u8, path: [:0]const u8) [:0]u8 {
    return memory.formatZ(buffer, "{s}/{s}", .{ dataPath, path });
}
