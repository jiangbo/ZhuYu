const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;
const Decompress = std.compress.flate.Decompress;

const signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

const Chunk = enum(u32) {
    IHDR = std.mem.readInt(u32, "IHDR", .big),
    PLTE = std.mem.readInt(u32, "PLTE", .big),
    tRNS = std.mem.readInt(u32, "tRNS", .big),
    IDAT = std.mem.readInt(u32, "IDAT", .big),
    IEND = std.mem.readInt(u32, "IEND", .big),
    _,
};

const Color = enum(u8) {
    gray = 0,
    rgb = 2,
    indexed = 3,
    grayAlpha = 4,
    rgba = 6,
    magic = 44, // 私有扩展：PLTE 是 RGBA 调色板。
};

const Filter = enum(u8) { none, sub, up, average, paeth };

const Header = extern struct {
    width: u32 align(1),
    height: u32 align(1),
    bitDepth: u8,
    color: Color,
    compression: u8,
    filter: u8,
    interlace: u8,
};

const Range = struct { start: usize, end: usize };

const ChunkData = struct {
    kind: Chunk,
    data: []const u8,
    range: Range,
};

const Decode = struct {
    flate: *Decompress,
    data: []u8,
    header: Header,
    row: []u8,
    prior: []u8,
};

const DataReader = struct {
    reader: Reader,
    bytes: []const u8,
    ranges: []const Range,
    // 原 IDAT 读取位置，buf 状态下表示预读到哪里。
    rangeIndex: usize = 0,
    rangeOffset: usize = 0,
    buf: [8]u8 = undefined, // flate 跨 IDAT 时拼少量连续字节。

    const vtable: Reader.VTable = .{
        .stream = stream,
        .readVec = readVec,
        .rebase = rebase,
    };

    fn init(bytes: []const u8, ranges: []const Range) DataReader {
        const reader = std.mem.zeroInit(std.Io.Reader, .{
            .vtable = &vtable,
        });
        return .{ .reader = reader, .bytes = bytes, .ranges = ranges };
    }

    fn stream(reader: *Reader, writer: *Writer, limit: Limit) !usize {
        const self: *@This() = @alignCast(@fieldParentPtr("reader", reader));
        if (limit == .nothing) return 0;
        if (reader.seek >= reader.end) try self.loadRange();

        const data = limit.slice(reader.buffer[reader.seek..reader.end]);
        const n = try writer.write(data);
        reader.seek += n;
        return n;
    }

    fn readVec(reader: *Reader, data: [][]u8) !usize {
        const self: *@This() = @alignCast(@fieldParentPtr("reader", reader));
        if (data[0].len == 0) {
            std.debug.assert(reader.seek == reader.end);
            try self.loadRange();
            return 0;
        }

        if (reader.seek >= reader.end) try self.loadRange();
        const start = reader.seek;
        for (data) |full| {
            if (full.len == 0) continue;
            if (reader.seek >= reader.end) break;

            const src = reader.buffer[reader.seek..reader.end];
            const min = @min(full.len, src.len);
            @memcpy(full[0..min], src[0..min]);
            reader.seek += min;
        }

        return reader.seek - start;
    }

    fn rebase(reader: *Reader, capacity: usize) !void {
        const self: *@This() = @alignCast(@fieldParentPtr("reader", reader));
        // 这里只给 zlib/deflate 用，输入最多预读 4 字节。
        std.debug.assert(capacity <= 4);
        if (reader.end - reader.seek >= capacity) return;

        if (reader.buffer.ptr == self.buf[0..].ptr) {
            self.rangeOffset -= reader.end - reader.seek;
            return try self.loadRange();
        }

        // 未消费的尾巴搬到 buf 头，再从后续 IDAT range 补满。
        const left = reader.buffer[reader.seek..reader.end];
        @memmove(self.buf[0..left.len], left);
        const need = self.buf.len - left.len;

        try self.loadRange();
        const src = reader.buffer[reader.seek..reader.end];
        // 假设小 IDAT 只在末尾，中间 IDAT 一定能补齐。
        const copy = @min(need, src.len);
        @memcpy(self.buf[left.len..][0..copy], src[0..copy]);
        self.rangeIndex -= 1;
        self.rangeOffset = reader.seek + copy;

        const len = left.len + copy;
        if (len < capacity) return error.ReadFailed;
        self.setReader(self.buf[0..len], 0);
    }

    fn loadRange(self: *DataReader) !void {
        while (self.rangeIndex < self.ranges.len) {
            const range = self.ranges[self.rangeIndex];
            self.rangeIndex += 1;
            const seek = self.rangeOffset;
            self.rangeOffset = 0;
            if (seek == range.end - range.start) continue;

            const buffer = self.bytes[range.start..range.end];
            self.setReader(@constCast(buffer), seek);
            return;
        }

        self.setReader(&.{}, 0);
        return error.EndOfStream;
    }

    fn setReader(self: *DataReader, buffer: []u8, seek: usize) void {
        self.reader.buffer = buffer;
        self.reader.seek = seek;
        self.reader.end = buffer.len;
    }
};

pub const Image = struct { width: i32, height: i32, data: []u8 };

pub fn loadIcon(allocator: Allocator, bytes: []const u8) !Image {
    if (std.mem.startsWith(u8, bytes, &signature)) {
        return load(allocator, bytes);
    }

    return loadIco(allocator, bytes);
}

pub fn load(allocator: Allocator, bytes: []const u8) !Image {
    var reader = Reader.fixed(bytes);
    const header = try readHeader(&reader);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var ranges: std.ArrayList(Range) = .empty;

    var rgb: []const u8 = &.{};
    var alpha: []const u8 = &.{};

    while (true) {
        const chunk = try readChunk(&reader);
        switch (chunk.kind) {
            .IDAT => try ranges.append(gpa, chunk.range),
            .PLTE => rgb = chunk.data,
            .tRNS => alpha = chunk.data,
            .IEND => break,
            else => {},
        }
    }
    if (ranges.items.len == 0) return error.MissingImageData;

    const len = header.width * header.height * 4;
    const pixelData = try allocator.alloc(u8, len);
    errdefer allocator.free(pixelData);

    var source = DataReader.init(bytes, ranges.items);

    const prior = try gpa.alloc(u8, header.width * 3);
    @memset(prior, 0);

    const buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
    var flate = Decompress.init(&source.reader, .zlib, buffer);
    const decode: Decode = .{
        .flate = &flate,
        .data = pixelData,
        .header = header,
        .row = try gpa.alloc(u8, header.width * 3),
        .prior = prior,
    };

    switch (header.color) {
        .rgb => try parseRgb(&decode),
        .rgba => try parseRgba(&decode),
        .gray => try parseGray(&decode),
        .indexed => {
            var buf: [256 * 4]u8 = undefined; // 256 色，每色 4 字节。
            for (0..rgb.len / 3) |i| {
                buf[i * 4 + 0] = rgb[i * 3 + 0];
                buf[i * 4 + 1] = rgb[i * 3 + 1];
                buf[i * 4 + 2] = rgb[i * 3 + 2];
                const a = if (i < alpha.len) alpha[i] else 255;
                buf[i * 4 + 3] = a;
            }
            const palette = buf[0 .. rgb.len / 3 * 4];
            try parseIndexed(&decode, palette);
        },
        .magic => try parseIndexed(&decode, rgb),
        else => return error.UnsupportedColor,
    }
    return .{
        .width = @intCast(header.width),
        .height = @intCast(header.height),
        .data = pixelData,
    };
}

const IconEntry = struct { width: usize, height: usize, payload: []const u8 };

fn loadIco(allocator: Allocator, bytes: []const u8) !Image {
    var reader = Reader.fixed(bytes);
    if (try reader.takeInt(u16, .little) != 0) return error.InvalidIcon;
    if (try reader.takeInt(u16, .little) != 1) return error.InvalidIcon;

    const count = try reader.takeInt(u16, .little);
    if (count == 0) return error.InvalidIcon;

    const dirStart: usize = 6;
    const iconCount: usize = count;
    const dirSize: usize = iconCount * 16;
    if (bytes.len < dirStart + dirSize) return error.InvalidIcon;

    var best: ?IconEntry = null;
    var bestArea: usize = 0;
    for (0..iconCount) |i| {
        const entry = bytes[dirStart + i * 16 ..][0..16];
        var entryReader = Reader.fixed(entry);

        const widthByte = try entryReader.takeByte();
        const heightByte = try entryReader.takeByte();
        _ = try entryReader.takeByte(); // 调色板颜色数。
        if (try entryReader.takeByte() != 0) return error.InvalidIcon;
        _ = try entryReader.takeInt(u16, .little); // 颜色平面。
        _ = try entryReader.takeInt(u16, .little); // 色深。

        const width: usize = if (widthByte == 0) 256 else widthByte;
        const height: usize = if (heightByte == 0) 256 else heightByte;
        const size: usize = try entryReader.takeInt(u32, .little);
        const offset: usize = try entryReader.takeInt(u32, .little);
        if (size == 0) return error.InvalidIcon;
        if (offset > bytes.len or size > bytes.len - offset) {
            return error.InvalidIcon;
        }

        const payload = bytes[offset .. offset + size];
        const area = width * height;
        if (area > bestArea) {
            best = .{ .width = width, .height = height, .payload = payload };
            bestArea = area;
        }
    }

    const entry = best orelse return error.UnsupportedIcon;
    if (std.mem.startsWith(u8, entry.payload, &signature)) {
        return load(allocator, entry.payload);
    }
    return loadDib(allocator, entry);
}

fn loadDib(allocator: Allocator, entry: IconEntry) !Image {
    const payload = entry.payload;
    var reader = Reader.fixed(payload);
    if (try reader.takeInt(u32, .little) != 40) return error.UnsupportedIcon;

    const width: usize = try reader.takeInt(u32, .little);
    const fullHeight: usize = try reader.takeInt(u32, .little);
    if (width == 0 or fullHeight == 0) return error.InvalidIcon;
    if (fullHeight % 2 != 0) return error.InvalidIcon;

    const height = fullHeight / 2;
    if (width != entry.width or height != entry.height) {
        return error.InvalidIcon;
    }
    if (try reader.takeInt(u16, .little) != 1) return error.InvalidIcon;
    if (try reader.takeInt(u16, .little) != 32) return error.UnsupportedIcon;
    if (try reader.takeInt(u32, .little) != 0) return error.UnsupportedIcon;
    _ = try reader.takeInt(u32, .little); // 位图数据长度。
    _ = try reader.takeInt(u32, .little); // 水平分辨率。
    _ = try reader.takeInt(u32, .little); // 垂直分辨率。
    _ = try reader.takeInt(u32, .little); // 调色板颜色数。
    _ = try reader.takeInt(u32, .little); // 重要颜色数。

    const srcLen = width * height * 4;
    if (payload.len < 40 + srcLen) return error.InvalidIcon;

    const pixelData = try allocator.alloc(u8, srcLen);
    errdefer allocator.free(pixelData);

    const pixels = payload[40 .. 40 + srcLen];
    for (0..height) |y| {
        const srcY = height - 1 - y;
        const src = pixels[srcY * width * 4 ..][0 .. width * 4];
        const dest = pixelData[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            dest[x * 4 + 0] = src[x * 4 + 2];
            dest[x * 4 + 1] = src[x * 4 + 1];
            dest[x * 4 + 2] = src[x * 4 + 0];
            dest[x * 4 + 3] = src[x * 4 + 3];
        }
    }

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .data = pixelData,
    };
}

fn readHeader(reader: *Reader) !Header {
    const head = try reader.take(signature.len);
    if (!std.mem.eql(u8, head, &signature)) {
        return error.InvalidSignature;
    }

    const first = try readChunk(reader);
    if (first.kind != .IHDR) return error.InvalidHeader;
    if (first.data.len != 13) return error.InvalidHeader;

    var dataReader = Reader.fixed(first.data);
    const header = try dataReader.takeStruct(Header, .big);

    if (header.width == 0 or header.height == 0) return error.InvalidHeader;
    if (header.width > 16384) return error.ImageTooLarge;
    if (header.height > 16384) return error.ImageTooLarge;
    if (header.bitDepth != 8) return error.UnsupportedBitDepth;
    switch (header.color) {
        .gray, .rgb, .rgba, .indexed, .magic => {},
        else => return error.UnsupportedColor,
    }
    if (header.compression != 0) return error.UnsupportedCompression;
    if (header.filter != 0) return error.UnsupportedFilter;
    if (header.interlace != 0) return error.UnsupportedInterlace;

    return header;
}

fn readChunk(reader: *Reader) !ChunkData {
    const dataLen = try reader.takeInt(u32, .big);
    const crcBytes = try reader.peek(dataLen + @sizeOf(Chunk));

    const kind = try reader.takeEnum(Chunk, .big);
    const start = reader.seek;
    const data = try reader.take(dataLen);
    const crc = try reader.takeInt(u32, .big);
    if (crc != std.hash.Crc32.hash(crcBytes)) return error.InvalidCrc;

    return .{
        .kind = kind,
        .data = data,
        .range = .{ .start = start, .end = start + data.len },
    };
}

fn parseIndexed(decode: *const Decode, palette: []const u8) !void {
    const width = decode.header.width;
    const row = decode.row[0..width];
    const prior = decode.prior[0..width];

    for (0..decode.header.height) |y| {
        const filter = try decode.flate.reader.takeEnum(Filter, .big);
        try decode.flate.reader.readSliceAll(row);
        unFilter(row, prior, 1, filter);

        const dest = decode.data[y * width * 4 ..][0 .. width * 4];
        for (row, 0..) |index, x| {
            const color = @as(usize, index) * 4;
            if (color + 4 > palette.len) return error.InvalidPaletteIndex;
            @memcpy(dest[x * 4 ..][0..4], palette[color..][0..4]);
        }

        @memcpy(prior, row);
    }
}

fn parseRgb(decode: *const Decode) !void {
    const width = decode.header.width;

    for (0..decode.header.height) |y| {
        const filter = try decode.flate.reader.takeEnum(Filter, .big);
        try decode.flate.reader.readSliceAll(decode.row);
        unFilter(decode.row, decode.prior, 3, filter);

        const dest = decode.data[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            dest[x * 4 + 0] = decode.row[x * 3 + 0];
            dest[x * 4 + 1] = decode.row[x * 3 + 1];
            dest[x * 4 + 2] = decode.row[x * 3 + 2];
            dest[x * 4 + 3] = 255;
        }

        @memcpy(decode.prior, decode.row);
    }
}

fn parseGray(decode: *const Decode) !void {
    const width = decode.header.width;
    const row = decode.row[0..width];
    const prior = decode.prior[0..width];

    for (0..decode.header.height) |y| {
        const filter = try decode.flate.reader.takeEnum(Filter, .big);
        try decode.flate.reader.readSliceAll(row);
        unFilter(row, prior, 1, filter);

        const dest = decode.data[y * width * 4 ..][0 .. width * 4];
        for (row, 0..) |value, x| {
            dest[x * 4 + 0] = 255;
            dest[x * 4 + 1] = 255;
            dest[x * 4 + 2] = 255;
            dest[x * 4 + 3] = value;
        }

        @memcpy(prior, row);
    }
}

fn parseRgba(decode: *const Decode) !void {
    const len = decode.header.width * 4;
    var pre: []const u8 = &.{};

    for (0..decode.header.height) |y| {
        const filter = try decode.flate.reader.takeEnum(Filter, .big);
        const dest = decode.data[y * len ..][0..len];
        try decode.flate.reader.readSliceAll(dest);
        unFilter(dest, pre, 4, filter);
        pre = dest;
    }
}

fn unFilter(cur: []u8, pre: []const u8, size: usize, f: Filter) void {
    switch (f) {
        .none => {},
        .sub => for (cur, 0..) |*value, i| {
            value.* +%= if (i >= size) cur[i - size] else 0;
        },
        .up => for (cur, 0..) |*value, i| {
            value.* +%= if (pre.len == 0) 0 else pre[i];
        },
        .average => for (cur, 0..) |*value, i| {
            const left = if (i >= size) cur[i - size] else 0;
            const up = if (pre.len == 0) 0 else pre[i];
            value.* +%= @intCast((@as(u16, left) + up) / 2);
        },
        .paeth => for (cur, 0..) |*value, i| {
            const left = if (i >= size) cur[i - size] else 0;
            const up = if (pre.len == 0) 0 else pre[i];
            var upLeft: u8 = 0;
            if (pre.len != 0 and i >= size) upLeft = pre[i - size];
            value.* +%= paeth(left, up, upLeft);
        },
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

const TestPng = struct {
    width: u32,
    height: u32,
    color: u8,
    scanlines: []const u8,
    bitDepth: u8 = 8,
    interlace: u8 = 0,
    plte: []const u8 = &.{},
    trns: []const u8 = &.{},
    splitIdat: bool = false,
    splitTail: usize = 0,
};

fn makeTestPng(allocator: Allocator, png: TestPng) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], png.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], png.height, .big);
    ihdr[8] = png.bitDepth;
    ihdr[9] = png.color;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = png.interlace;
    try appendChunk(&result, allocator, "IHDR", &ihdr);

    if (png.plte.len != 0) {
        try appendChunk(&result, allocator, "PLTE", png.plte);
    }
    if (png.trns.len != 0) {
        try appendChunk(&result, allocator, "tRNS", png.trns);
    }

    const zlib = try makeStoredZlib(allocator, png.scanlines);
    defer allocator.free(zlib);
    if (png.splitTail != 0) {
        const mid = zlib.len - png.splitTail;
        try appendChunk(&result, allocator, "IDAT", zlib[0..mid]);
        try appendChunk(&result, allocator, "IDAT", zlib[mid..]);
    } else if (png.splitIdat) {
        const mid = zlib.len / 2;
        try appendChunk(&result, allocator, "IDAT", zlib[0..mid]);
        try appendChunk(&result, allocator, "IDAT", zlib[mid..]);
    } else {
        try appendChunk(&result, allocator, "IDAT", zlib);
    }
    try appendChunk(&result, allocator, "IEND", &.{});

    return result.toOwnedSlice(allocator);
}

fn makeTestIcon(allocator: Allocator, png: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, &.{
        0, 0, // 保留字段。
        1, 0, // 普通图标。
        1, 0, // 一个目录项。
        2, 1, // 宽高。
        0, 0, // 无调色板，保留字段。
        1, 0, // 颜色平面。
        32, 0, // 32 位颜色。
    });

    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, @intCast(png.len), .little);
    try result.appendSlice(allocator, &size);

    var offset: [4]u8 = undefined;
    std.mem.writeInt(u32, &offset, 6 + 16, .little);
    try result.appendSlice(allocator, &offset);

    try result.appendSlice(allocator, png);
    return result.toOwnedSlice(allocator);
}

fn makeTestDibIcon(allocator: Allocator) ![]u8 {
    const dib = [_]u8{
        40, 0, 0, 0, // BITMAPINFOHEADER 长度。
        2, 0, 0, 0, // 宽。
        4, 0, 0, 0, // 高度包含 XOR 和 AND 两部分。
        1, 0, // 颜色平面。
        32, 0, // 32 位 BGRA。
        0, 0, 0, 0, // BI_RGB，无压缩。
        16, 0, 0, 0, // 像素数据长度。
        0, 0, 0, 0, // 水平分辨率。
        0, 0, 0, 0, // 垂直分辨率。
        0, 0, 0, 0, // 调色板颜色数。
        0, 0, 0, 0, // 重要颜色数。
        11, 10, 9, 12, // 底行像素 1。
        15, 14, 13, 16, // 底行像素 2。
        3, 2, 1, 4, // 顶行像素 1。
        7, 6, 5, 8, // 顶行像素 2。
    };

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, &.{
        0, 0, // 保留字段。
        1, 0, // 普通图标。
        1, 0, // 一个目录项。
        2, 2, // 宽高。
        0, 0, // 无调色板，保留字段。
        1, 0, // 颜色平面。
        32, 0, // 32 位颜色。
    });

    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, dib.len, .little);
    try result.appendSlice(allocator, &size);

    var offset: [4]u8 = undefined;
    std.mem.writeInt(u32, &offset, 6 + 16, .little);
    try result.appendSlice(allocator, &offset);

    try result.appendSlice(allocator, &dib);
    return result.toOwnedSlice(allocator);
}

fn makeStoredZlib(
    allocator: Allocator,
    data: []const u8,
) ![]u8 {
    if (data.len > std.math.maxInt(u16)) return error.TestDataTooLarge;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, &.{ 0x78, 0x01, 0x01 });

    var lenBytes: [2]u8 = undefined;
    const len: u16 = @intCast(data.len);
    std.mem.writeInt(u16, &lenBytes, len, .little);
    try result.appendSlice(allocator, &lenBytes);
    std.mem.writeInt(u16, &lenBytes, ~len, .little);
    try result.appendSlice(allocator, &lenBytes);

    try result.appendSlice(allocator, data);

    var adlerBytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adlerBytes, std.hash.Adler32.hash(data), .big);
    try result.appendSlice(allocator, &adlerBytes);

    return result.toOwnedSlice(allocator);
}

fn appendChunk(
    result: *std.ArrayList(u8),
    allocator: Allocator,
    kind: []const u8,
    data: []const u8,
) !void {
    if (kind.len != 4) return error.InvalidChunk;

    var lenBytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenBytes, @intCast(data.len), .big);
    try result.appendSlice(allocator, &lenBytes);
    try result.appendSlice(allocator, kind);
    try result.appendSlice(allocator, data);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);

    var crcBytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcBytes, crc.final(), .big);
    try result.appendSlice(allocator, &crcBytes);
}

test "load rgba png" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 6,
        .scanlines = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
    });
    defer allocator.free(png);

    const image = try load(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqual(@as(i32, 2), image.width);
    try std.testing.expectEqual(@as(i32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{
        1, 2, 3, 4,
        5, 6, 7, 8,
    }, image.data);
}

test "load icon from png" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 1,
        .height = 1,
        .color = 6,
        .scanlines = &.{ 0, 1, 2, 3, 4 },
    });
    defer allocator.free(png);

    const image = try loadIcon(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqual(@as(i32, 1), image.width);
    try std.testing.expectEqual(@as(i32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, image.data);
}

test "load icon from ico png payload" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 6,
        .scanlines = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
    });
    defer allocator.free(png);

    const icon = try makeTestIcon(allocator, png);
    defer allocator.free(icon);

    const image = try loadIcon(allocator, icon);
    defer allocator.free(image.data);

    try std.testing.expectEqual(@as(i32, 2), image.width);
    try std.testing.expectEqual(@as(i32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{
        1, 2, 3, 4,
        5, 6, 7, 8,
    }, image.data);
}

test "load icon from ico dib payload" {
    const allocator = std.testing.allocator;
    const icon = try makeTestDibIcon(allocator);
    defer allocator.free(icon);

    const image = try loadIcon(allocator, icon);
    defer allocator.free(image.data);

    try std.testing.expectEqual(@as(i32, 2), image.width);
    try std.testing.expectEqual(@as(i32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    }, image.data);
}

test "load rgb png" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 2,
        .scanlines = &.{ 0, 1, 2, 3, 4, 5, 6 },
    });
    defer allocator.free(png);

    const image = try load(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqualSlices(u8, &.{
        1, 2, 3, 255,
        4, 5, 6, 255,
    }, image.data);
}

test "load gray png" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 0,
        .scanlines = &.{ 0, 10, 20 },
    });
    defer allocator.free(png);

    const image = try load(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqualSlices(u8, &.{
        255, 255, 255, 10,
        255, 255, 255, 20,
    }, image.data);
}

test "load indexed png with trns" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 3,
        .plte = &.{ 10, 20, 30, 40, 50, 60 },
        .trns = &.{ 70, 80 },
        .scanlines = &.{ 0, 0, 1 },
    });
    defer allocator.free(png);

    const image = try load(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqualSlices(u8, &.{
        10, 20, 30, 70,
        40, 50, 60, 80,
    }, image.data);
}

test "load magic png with rgba palette" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 44,
        .plte = &.{ 10, 20, 30, 40, 50, 60, 70, 80 },
        .scanlines = &.{ 0, 0, 1 },
        .splitIdat = true,
    });
    defer allocator.free(png);

    const image = try load(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqualSlices(u8, &.{
        10, 20, 30, 40,
        50, 60, 70, 80,
    }, image.data);
}

test "load png with small tail idat" {
    const allocator = std.testing.allocator;
    const png = try makeTestPng(allocator, .{
        .width = 2,
        .height = 1,
        .color = 6,
        .scanlines = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        .splitTail = 1,
    });
    defer allocator.free(png);

    const image = try load(allocator, png);
    defer allocator.free(image.data);

    try std.testing.expectEqualSlices(u8, &.{
        1, 2, 3, 4,
        5, 6, 7, 8,
    }, image.data);
}

test "reject unsupported png header" {
    const allocator = std.testing.allocator;
    const bitDepthPng = try makeTestPng(allocator, .{
        .width = 1,
        .height = 1,
        .color = 6,
        .bitDepth = 16,
        .scanlines = &.{ 0, 1, 2, 3, 4 },
    });
    defer allocator.free(bitDepthPng);
    try std.testing.expectError(
        error.UnsupportedBitDepth,
        load(allocator, bitDepthPng),
    );

    const interlacePng = try makeTestPng(allocator, .{
        .width = 1,
        .height = 1,
        .color = 6,
        .interlace = 1,
        .scanlines = &.{ 0, 1, 2, 3, 4 },
    });
    defer allocator.free(interlacePng);
    try std.testing.expectError(
        error.UnsupportedInterlace,
        load(allocator, interlacePng),
    );
}
