//! 通用二进制编解码；数值使用小端序，切片先写入 u64 长度。
//! 支持数值、布尔、枚举、可选值、数组、向量、结构体、带标签联合和切片。
//! ArrayList 只保存元素，读取后容量等于元素数量。
const std = @import("std");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// 写入 ZHYU 标识、u32 小端版本号和编码数据，不刷新流。
pub fn encodeVersion(w: *Writer, version: u32, value: anytype) Writer.Error!void {
    try w.writeAll("ZHYU");
    try w.writeInt(u32, version, .little);
    try encode(w, value);
}

/// 读取并验证版本头，随后由调用方选择类型调用 decode。
pub fn readVersion(r: *Reader) (Reader.Error || error{InvalidData})!u32 {
    if (!std.mem.eql(u8, try r.take(4), "ZHYU")) return error.InvalidData;
    return r.takeInt(u32, .little);
}

/// 将值写入调用方提供的流，不添加文件头，也不刷新流。
/// 调用方可在写入文件前对编码结果加密或压缩。
pub fn encode(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try w.writeByte(@intFromBool(value)),
        .int => {
            const Int = switch (T) {
                usize => u64,
                isize => i64,
                else => std.math.ByteAlignedInt(T),
            };
            try w.writeInt(Int, value, .little);
        },
        .float => {
            const Int = @Int(.unsigned, @bitSizeOf(T));
            try w.writeInt(Int, @bitCast(value), .little);
        },
        .@"enum" => try encode(w, @backingInt(value)),
        .optional => {
            try w.writeByte(@intFromBool(value != null));
            if (value) |item| try encode(w, item);
        },
        .array => for (value) |item| try encode(w, item),
        .vector => |info| {
            const array: [info.len]info.child = value;
            try encode(w, array);
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("expected a tagged union");
            try encode(w, std.meta.activeTag(value));
            switch (value) {
                inline else => |item| try encode(w, item),
            }
        },
        .@"struct" => |info| {
            if (comptime isArrayList(T)) return encode(w, value.items);
            inline for (info.field_names) |name| {
                try encode(w, @field(value, name));
            }
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("expected a slice");
            try w.writeInt(u64, value.len, .little);
            for (value) |item| try encode(w, item);
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

/// 从调用方提供的流读取一个值，切片和 ArrayList 使用传入的分配器分配。
/// 建议传入 arena 的分配器，以便成功或失败后统一释放。
/// 只读取该值所需的字节，剩余内容由调用方处理。
pub fn decode(r: *Reader, comptime T: type, gpa_: Allocator) //
(Reader.Error || Allocator.Error || error{InvalidData})!T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => (try r.takeByte()) != 0,
        .int => blk: {
            const Int = switch (T) {
                usize => u64,
                isize => i64,
                else => std.math.ByteAlignedInt(T),
            };
            const value = try r.takeInt(Int, .little);
            break :blk std.math.cast(T, value) orelse return error.InvalidData;
        },
        .float => blk: {
            const Int = @Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(try r.takeInt(Int, .little));
        },
        .@"enum" => |info| blk: {
            const value = try decode(r, info.tag_type, gpa_);
            break :blk std.enums.fromInt(T, value) orelse return error.InvalidData;
        },
        .optional => |info| if (try r.takeByte() == 0)
            null
        else
            try decode(r, info.child, gpa_),
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decode(r, info.child, gpa_);
            if (comptime info.sentinel()) |sentinel| {
                result[info.len] = sentinel;
            }
            break :blk result;
        },
        .vector => |info| blk: {
            const array = try decode(r, [info.len]info.child, gpa_);
            break :blk array;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse @compileError("expected a tagged union");
            const tag = try decode(r, Tag, gpa_);
            inline for (info.field_names, info.field_types) |name, Field| {
                if (@field(Tag, name) == tag) {
                    const value = try decode(r, Field, gpa_);
                    break :blk @unionInit(T, name, value);
                }
            }
            return error.InvalidData;
        },
        .@"struct" => |info| blk: {
            if (comptime isArrayList(T)) {
                const items = try decode(r, T.Slice, gpa_);
                break :blk T.fromOwnedSlice(items);
            }
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| {
                @field(result, name) = try decode(r, Field, gpa_);
            }
            break :blk result;
        },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("expected a slice");
            const len = std.math.cast(usize, try r.takeInt(u64, .little));
            const alignment = info.attrs.@"align" orelse @alignOf(info.child);
            const items = try gpa_.allocWithOptions(
                info.child,
                len orelse return error.InvalidData,
                std.mem.Alignment.fromByteUnits(alignment),
                info.sentinel(),
            );
            for (items) |*item| item.* = try decode(r, info.child, gpa_);
            break :blk items;
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    };
}

// 按标准库类型识别 ArrayList，避免将同名字段的普通结构体当作列表。
fn isArrayList(comptime T: type) bool {
    if (!@hasField(T, "items")) return false;
    const info = switch (@typeInfo(@FieldType(T, "items"))) {
        .pointer => |info| info,
        else => return false,
    };
    if (info.size != .slice) return false;
    const alignment = info.attrs.@"align" orelse @alignOf(info.child);
    return T == std.array_list.Aligned(info.child, .fromByteUnits(alignment));
}
