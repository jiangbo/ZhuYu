//! 内存中的 Ogg Vorbis 播放器，支持单/双声道和交错 f32 输出。
//! 码本、Floor 1、Residue 和重叠窗口参考 stb_vorbis 1.22。
//! 来源与许可见仓库根目录 licenses/vorbis.txt。控制和采样由调用方同步。
const std = @import("std");

/// 持有压缩包、解码配置和播放状态；采样阶段不分配内存。
pub const Player = struct {
    arena: std.heap.ArenaAllocator,
    sampleRate: u32,
    channels: u8,
    sampleCount: usize,
    packets: []const Packet,
    books: []Book = &.{},
    floors: []Floor = &.{},
    residues: []Residue = &.{},
    maps: []Map = &.{},
    modes: []Mode = &.{},
    blocks: [2]Mdct = undefined,
    work: []Mdct.Complex = &.{},
    buffers: [2][]f32 = undefined,
    previous: [2][]f32 = undefined,
    floorY: [2][250]i32 = undefined,
    classes: [2][]u8 = undefined,
    packetIndex: usize = 3,
    previousLength: usize = 0,
    start: usize = 0,
    end: usize = 0,
    decoded: usize = 0,
    discard: usize = 0,

    /// 复制音频包并解析头部；返回后调用方可以释放原始文件。
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Player {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const storage = arena.allocator();
        const stream = try readOgg(storage, data);
        if (stream.packets.len < 3) return error.InvalidVorbis;
        const header = stream.packets[0].data;
        if (header.len != 30 or header[0] != 1 or
            !std.mem.eql(u8, header[1..7], "vorbis"))
            return error.InvalidVorbis;
        if (std.mem.readInt(u32, header[7..11], .little) != 0)
            return error.UnsupportedVorbisVersion;
        const channels = header[11];
        if (channels != 1 and channels != 2)
            return error.UnsupportedChannels;
        const rate = std.mem.readInt(u32, header[12..16], .little);
        if (rate == 0 or header[29] & 1 == 0) return error.InvalidVorbis;
        const small = header[28] & 15;
        const large = header[28] >> 4;
        if (small < 6 or large > 13 or small > large)
            return error.InvalidVorbis;
        const comment = stream.packets[1].data;
        if (comment.len < 7 or comment[0] != 3 or
            !std.mem.eql(u8, comment[1..7], "vorbis"))
            return error.InvalidVorbis;
        const setup = stream.packets[2].data;
        if (setup.len < 7 or setup[0] != 5 or
            !std.mem.eql(u8, setup[1..7], "vorbis"))
            return error.InvalidVorbis;

        var self: Player = .{
            .arena = arena,
            .sampleRate = rate,
            .channels = channels,
            .sampleCount = stream.samples,
            .packets = stream.packets,
        };
        var bits: Bits = .{ .data = setup[7..] };
        try self.readSetup(storage, &bits);
        self.blocks[0] = try Mdct.init(storage, @as(usize, 1) << @intCast(small));
        self.blocks[1] = try Mdct.init(storage, @as(usize, 1) << @intCast(large));
        const size = self.blocks[1].size;
        self.work = try storage.alloc(Mdct.Complex, size / 4);
        for (0..channels) |i| {
            self.buffers[i] = try storage.alloc(f32, size);
            self.previous[i] = try storage.alloc(f32, size / 2);
            // 一次 Residue 最多处理两声道交错的半块，每个分区至少一个值。
            self.classes[i] = try storage.alloc(u8, size + 256);
        }
        self.arena = arena;
        return self;
    }

    /// 释放压缩包、配置和工作缓冲；调用前停止音频线程使用它。
    pub fn deinit(self: *Player) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// 保留配置和内存，仅清除播放进度和前一块窗口。
    pub fn reset(self: *Player) void {
        self.packetIndex = 3;
        self.previousLength = 0;
        self.start = 0;
        self.end = 0;
        self.decoded = 0;
        self.discard = 0;
    }

    /// 填充交错 f32，返回帧数；单声道复制，双声道转单声道取平均。
    pub fn fillSamples(self: *Player, output: []f32, channels: i32) i32 {
        std.debug.assert(channels == 1 or channels == 2);
        const sides: usize = @intCast(channels);
        std.debug.assert(output.len % sides == 0);
        var frames: usize = 0;
        while (frames < output.len / sides) {
            if (self.start == self.end) {
                const ready = self.readFrame() catch |err|
                    std.debug.panic("vorbis decode failed: {}", .{err});
                if (!ready) break;
                if (self.start == self.end) continue;
            }
            const count = @min(self.end - self.start, output.len / sides - frames);
            const left = self.buffers[0][self.start..][0..count];
            const right = self.buffers[self.channels - 1][self.start..][0..count];
            for (left, right, 0..) |l, r, i| {
                const index = (frames + i) * sides;
                if (sides == 1) {
                    output[index] = (l + r) * 0.5;
                } else {
                    output[index] = l;
                    output[index + 1] = r;
                }
            }
            self.start += count;
            frames += count;
        }
        return @intCast(frames);
    }

    /// 读取一块频谱，完成声道还原、逆变换和前后窗口重叠。
    fn readFrame(self: *Player) !bool {
        if (self.decoded == self.sampleCount) return false;
        if (self.packetIndex == self.packets.len) return error.TruncatedVorbis;
        var bits: Bits = .{ .data = self.packets[self.packetIndex].data };
        self.packetIndex += 1;
        if (try bits.read(1) != 0) return error.InvalidVorbis;
        const modeIndex = try bits.read(bitCount(self.modes.len - 1));
        if (modeIndex >= self.modes.len) return error.InvalidVorbis;
        const mode = self.modes[modeIndex];
        const block = self.blocks[@intFromBool(mode.large)];
        const size = block.size;
        const half = size / 2;
        const small = self.blocks[0].size;
        var left: usize = 0;
        var right = half;
        var rightEnd = size;
        if (mode.large) {
            if (try bits.read(1) == 0) left = (size - small) / 4;
            if (try bits.read(1) == 0) {
                right = (size * 3 - small) / 4;
                rightEnd = (size * 3 + small) / 4;
            }
        }
        const map = self.maps[mode.map];
        var active: [2]bool = .{ false, false };
        for (0..self.channels) |i| {
            const floor = &self.floors[map.floors[map.mux[i]]];
            active[i] = floor.decode(&bits, &self.floorY[i]) catch |err|
                switch (err) {
                    error.EndOfPacket => false,
                    else => return err,
                };
            @memset(self.buffers[i][0..half], 0);
        }
        var needed = active;
        for (map.coupling) |pair| {
            if (needed[pair[0]] or needed[pair[1]]) {
                needed[pair[0]] = true;
                needed[pair[1]] = true;
            }
        }
        for (map.residues, 0..) |residue, submap| {
            var group: Group = .{ .length = half };
            for (0..self.channels) |i| {
                if (map.mux[i] != submap) continue;
                group.buffers[group.count] = self.buffers[i][0..half];
                group.active[group.count] = needed[i];
                group.count += 1;
            }
            const request: ResidueRequest = .{ .residue = residue, .group = group };
            self.readResidue(&bits, request) catch |err| switch (err) {
                // 规范允许音频包提前结束，未写入的频谱继续为零。
                error.EndOfPacket => {},
                else => return err,
            };
        }
        var step = map.coupling.len;
        while (step > 0) {
            step -= 1;
            const pair = map.coupling[step];
            const magnitude = self.buffers[pair[0]][0..half];
            const angle = self.buffers[pair[1]][0..half];
            for (magnitude, angle) |*m, *a| {
                const old = m.*;
                if (old > 0) {
                    if (a.* > 0) a.* = old - a.* else {
                        m.* = old + a.*;
                        a.* = old;
                    }
                } else {
                    if (a.* > 0) a.* = old + a.* else {
                        m.* = old - a.*;
                        a.* = old;
                    }
                }
            }
        }
        for (0..self.channels) |i| {
            const buffer = self.buffers[i];
            if (active[i]) {
                const floor = &self.floors[map.floors[map.mux[i]]];
                try floor.apply(buffer[0..half], &self.floorY[i]);
            } else @memset(buffer[0..half], 0);
            block.run(buffer, self.work);
            const previousLength = self.previousLength;
            if (previousLength != 0) {
                const window = if (previousLength == small / 2)
                    self.blocks[0].window
                else
                    self.blocks[1].window;
                if (left + previousLength > size) return error.InvalidVorbis;
                for (0..previousLength) |j| {
                    buffer[left + j] = buffer[left + j] * window[j] +
                        self.previous[i][j] * window[previousLength - 1 - j];
                }
            }
            @memcpy(self.previous[i][0 .. rightEnd - right], buffer[right..rightEnd]);
        }
        const first = self.previousLength == 0;
        self.previousLength = rightEnd - right;
        self.start = left;
        self.end = left;
        if (first) {
            self.discard = size - rightEnd;
        } else {
            const discard = @min(self.discard, right - left);
            self.discard -= discard;
            self.start += discard;
            const count = @min(right - self.start, self.sampleCount - self.decoded);
            self.end = self.start + count;
            self.decoded += count;
        }
        return true;
    }

    /// 解析码本、频谱模型、声道映射和音频块模式。
    fn readSetup(self: *Player, allocator: std.mem.Allocator, bits: *Bits) !void {
        self.books = try allocator.alloc(Book, try bits.read(8) + 1);
        for (self.books) |*book| book.* = try Book.init(.{
            .store = allocator,
            .temp = self.arena.child_allocator,
        }, bits);
        const times = try bits.read(6) + 1;
        for (0..times) |_| if (try bits.read(16) != 0) return error.InvalidVorbis;
        self.floors = try allocator.alloc(Floor, try bits.read(6) + 1);
        for (self.floors) |*floor| {
            if (try bits.read(16) != 1) return error.UnsupportedFloor;
            floor.* = try Floor.init(allocator, .{ .bits = bits, .books = self.books });
        }
        self.residues = try allocator.alloc(Residue, try bits.read(6) + 1);
        for (self.residues) |*residue| {
            residue.* = .{
                .kind = try bits.read(16),
                .begin = try bits.read(24),
                .end = try bits.read(24),
                .size = try bits.read(24) + 1,
                .count = try bits.read(6) + 1,
                .book = try bits.read(8),
            };
            if (residue.kind > 2 or residue.begin > residue.end or
                residue.book >= self.books.len) return error.InvalidVorbis;
            var masks: [64]u8 = undefined;
            for (masks[0..residue.count]) |*mask| {
                const low = try bits.read(3);
                const high = if (try bits.read(1) != 0) try bits.read(5) else 0;
                mask.* = @intCast(low | high << 3);
            }
            residue.books = try allocator.alloc([8]i16, residue.count);
            for (residue.books, masks[0..residue.count]) |*books, mask| {
                for (books, 0..) |*book, pass| {
                    book.* = if (mask & (@as(u8, 1) << @intCast(pass)) != 0)
                        @intCast(try bits.read(8))
                    else
                        -1;
                    if (book.* >= self.books.len) return error.InvalidVorbis;
                }
            }
        }
        self.maps = try allocator.alloc(Map, try bits.read(6) + 1);
        for (self.maps) |*map| {
            if (try bits.read(16) != 0) return error.UnsupportedMapping;
            map.* = .{};
            const submaps = if (try bits.read(1) != 0) try bits.read(4) + 1 else 1;
            if (try bits.read(1) != 0) {
                map.coupling = try allocator.alloc([2]u8, try bits.read(8) + 1);
                for (map.coupling) |*pair| {
                    pair[0] = @intCast(try bits.read(bitCount(self.channels - 1)));
                    pair[1] = @intCast(try bits.read(bitCount(self.channels - 1)));
                    if (pair[0] == pair[1] or pair[0] >= self.channels or
                        pair[1] >= self.channels) return error.InvalidVorbis;
                }
            }
            if (try bits.read(2) != 0) return error.InvalidVorbis;
            if (submaps > 1) {
                for (map.mux[0..self.channels]) |*mux| {
                    mux.* = @intCast(try bits.read(4));
                    if (mux.* >= submaps) return error.InvalidVorbis;
                }
            }
            map.floors = try allocator.alloc(u8, submaps);
            map.residues = try allocator.alloc(u8, submaps);
            for (map.floors, map.residues) |*floor, *residue| {
                _ = try bits.read(8);
                floor.* = @intCast(try bits.read(8));
                residue.* = @intCast(try bits.read(8));
                if (floor.* >= self.floors.len or residue.* >= self.residues.len)
                    return error.InvalidVorbis;
            }
        }
        self.modes = try allocator.alloc(Mode, try bits.read(6) + 1);
        for (self.modes) |*mode| {
            mode.large = try bits.read(1) != 0;
            if (try bits.read(16) != 0 or try bits.read(16) != 0)
                return error.InvalidVorbis;
            mode.map = try bits.read(8);
            if (mode.map >= self.maps.len) return error.InvalidVorbis;
        }
        if (try bits.read(1) != 1) return error.InvalidVorbis;
        // Floor 解码需要码本；保存切片，不复制码本内容。
        for (self.floors) |*floor| floor.books = self.books;
    }

    /// 按八轮分类和向量解码，还原一个子映射的 Residue 频谱。
    fn readResidue(self: *Player, bits: *Bits, request: ResidueRequest) !void {
        const residue = self.residues[request.residue];
        const group = request.group;
        if (group.count == 0) return;
        const interleaved = residue.kind == 2;
        const limit = group.length * (if (interleaved) group.count else 1);
        const begin = @min(residue.begin, limit);
        const end = @min(residue.end, limit);
        const parts = (end - begin) / residue.size;
        const classbook = &self.books[residue.book];
        const words = classbook.dimensions;
        const sides = if (interleaved) @as(usize, 1) else group.count;
        if (interleaved and !group.active[0] and
            (group.count == 1 or !group.active[1])) return;
        for (0..8) |pass| {
            var part: usize = 0;
            while (part < parts) {
                if (pass == 0) {
                    for (0..sides) |side| {
                        if (!interleaved and !group.active[side]) continue;
                        var value = try classbook.scalar(bits);
                        var k = words;
                        while (k > 0) {
                            k -= 1;
                            self.classes[side][part + k] =
                                @intCast(value % residue.count);
                            value /= residue.count;
                        }
                    }
                }
                for (0..@min(words, parts - part)) |_| {
                    for (0..sides) |side| {
                        if (!interleaved and !group.active[side]) continue;
                        const kind = self.classes[side][part];
                        const bookIndex = residue.books[kind][pass];
                        if (bookIndex < 0) continue;
                        const book = &self.books[@intCast(bookIndex)];
                        if (book.vectors.len == 0) return error.InvalidVorbis;
                        const offset = begin + part * residue.size;
                        if (residue.kind == 0) {
                            const stride = residue.size / book.dimensions;
                            for (0..stride) |i| {
                                const values = try book.vector(bits);
                                for (values, 0..) |value, j| {
                                    const index = offset + i + j * stride;
                                    group.buffers[side][index] += value;
                                }
                            }
                        } else {
                            var i: usize = 0;
                            while (i < residue.size) {
                                const values = try book.vector(bits);
                                const count = @min(values.len, residue.size - i);
                                for (values[0..count]) |value| {
                                    const index = offset + i;
                                    if (interleaved) {
                                        const sideIndex = index % group.count;
                                        const sampleIndex = index / group.count;
                                        group.buffers[sideIndex][sampleIndex] += value;
                                    } else group.buffers[side][index] += value;
                                    i += 1;
                                }
                            }
                        }
                    }
                    part += 1;
                }
            }
        }
    }
};

const Packet = struct { data: []const u8 };
const Stream = struct { packets: []Packet, samples: usize };
const Mode = struct { large: bool, map: usize };
const Map = struct {
    mux: [2]u8 = .{ 0, 0 },
    coupling: [][2]u8 = &.{},
    floors: []u8 = &.{},
    residues: []u8 = &.{},
};
const Residue = struct {
    kind: u32,
    begin: usize,
    end: usize,
    size: usize,
    count: u32,
    book: usize,
    books: [][8]i16 = &.{},
};
const Group = struct {
    buffers: [2][]f32 = undefined,
    active: [2]bool = .{ false, false },
    count: usize = 0,
    length: usize,
};
const ResidueRequest = struct { residue: usize, group: Group };

/// 只接收一个完整逻辑流；初始化时去掉页头，音频包连续存储。
fn readOgg(allocator: std.mem.Allocator, data: []const u8) !Stream {
    var position: usize = 0;
    var count: usize = 0;
    var bytes: usize = 0;
    var serial: ?u32 = null;
    var samples: ?usize = null;
    while (position < data.len) {
        if (data.len - position < 27) return error.TruncatedOgg;
        const header = data[position..][0..27];
        if (!std.mem.eql(u8, header[0..4], "OggS") or header[4] != 0)
            return error.InvalidOgg;
        const current = std.mem.readInt(u32, header[14..18], .little);
        if (serial) |value| {
            if (value != current or header[5] & 2 != 0)
                return error.UnsupportedOggStreams;
        } else {
            if (header[5] & 2 == 0) return error.InvalidOgg;
            serial = current;
        }
        position += 27;
        if (header[26] > data.len - position) return error.TruncatedOgg;
        const lacing = data[position..][0..header[26]];
        var length: usize = 0;
        for (lacing) |value| {
            length += value;
            if (value < 255) count += 1;
        }
        position += lacing.len;
        if (length > data.len - position) return error.TruncatedOgg;
        position += length;
        bytes += length;
        if (header[5] & 4 != 0) {
            const granule = std.mem.readInt(u64, header[6..14], .little);
            if (granule == std.math.maxInt(u64) or position != data.len)
                return error.UnsupportedOggStreams;
            samples = std.math.cast(usize, granule) orelse return error.OggTooLong;
        }
    }
    const total = samples orelse return error.TruncatedOgg;
    const packets = try allocator.alloc(Packet, count);
    const payload = try allocator.alloc(u8, bytes);
    position = 0;
    var written: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (position < data.len) {
        const segments = data[position + 26];
        position += 27;
        const lacing = data[position..][0..segments];
        position += segments;
        for (lacing) |length| {
            @memcpy(payload[written..][0..length], data[position..][0..length]);
            position += length;
            written += length;
            if (length < 255) {
                packets[index] = .{ .data = payload[start..written] };
                index += 1;
                start = written;
            }
        }
    }
    if (start != written) return error.TruncatedOgg;
    return .{ .packets = packets, .samples = total };
}

/// Vorbis 位流按低位优先读取；缓存最多提前读取四个字节。
const Bits = struct {
    data: []const u8,
    index: usize = 0,
    value: u64 = 0,
    count: u6 = 0,

    // 补充低位缓存，包尾保留实际可读取的位数。
    fn fill(self: *Bits, count: u6) void {
        while (self.count < count and self.index < self.data.len) {
            self.value |= @as(u64, self.data[self.index]) << self.count;
            self.count += 8;
            self.index += 1;
        }
    }

    // 读取并消费指定数量的位，包尾由上层按头部或音频包分别处理。
    fn read(self: *Bits, count: u6) !u32 {
        self.fill(count);
        if (self.count < count) return error.EndOfPacket;
        const value: u32 = @truncate(self.value & ((@as(u64, 1) << count) - 1));
        self.value >>= count;
        self.count -= count;
        return value;
    }
};

// Vorbis 的 ilog，零需要零位，其余返回最高有效位的位置加一。
fn bitCount(value: usize) u6 {
    return @intCast(@bitSizeOf(usize) - @clz(value));
}

const Entry = struct {
    word: u32, // 最高位在前的码字，用于较长码字的二分查找。
    symbol: u32,
    length: u6,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return a.word < b.word;
    }
};

// 初始化的长期和临时分配器分开，临时长度表不会留在 arena 中。
const BookAlloc = struct { store: std.mem.Allocator, temp: std.mem.Allocator };

/// 稀疏码本只保存有编码的条目，短码走十位查表。
const Book = struct {
    dimensions: usize,
    entries: []Entry,
    fast: [1024]i32 = @splat(-1),
    vectors: []f32 = &.{},

    // 建立码字和短码表，并把压缩向量展开成直接索引的浮点数组。
    fn init(memory: BookAlloc, bits: *Bits) !Book {
        const allocator = memory.store;
        if (try bits.read(24) != 0x564342) return error.InvalidVorbis;
        const dimensions = try bits.read(16);
        const count = try bits.read(24);
        if (dimensions == 0 or count == 0) return error.InvalidVorbis;
        // 长度表和压缩向量仅供初始化，避免把临时空间留在长期 arena 中。
        const lengths = try memory.temp.alloc(u8, count);
        defer memory.temp.free(lengths);
        @memset(lengths, 0);
        var present: usize = 0;
        if (try bits.read(1) != 0) {
            var length = try bits.read(5) + 1;
            var index: usize = 0;
            while (index < count) : (length += 1) {
                if (length > 32) return error.InvalidVorbis;
                const run = try bits.read(bitCount(count - index));
                if (run > count - index) return error.InvalidVorbis;
                @memset(lengths[index..][0..run], @intCast(length));
                index += run;
            }
            present = count;
        } else {
            const sparse = try bits.read(1) != 0;
            for (lengths) |*length| {
                if (!sparse or try bits.read(1) != 0) {
                    length.* = @intCast(try bits.read(5) + 1);
                    present += 1;
                }
            }
        }
        var self: Book = .{
            .dimensions = dimensions,
            .entries = try allocator.alloc(Entry, present),
        };
        var available: [33]u32 = @splat(0);
        var index: usize = 0;
        for (lengths, 0..) |length, symbol| {
            if (length == 0) continue;
            var word: u32 = 0;
            if (index == 0) {
                for (1..length + 1) |i|
                    available[i] = @as(u32, 1) << @intCast(32 - i);
            } else {
                var depth: usize = length;
                while (depth != 0 and available[depth] == 0) depth -= 1;
                if (depth == 0) return error.InvalidVorbis;
                word = available[depth];
                available[depth] = 0;
                var i: usize = length;
                while (i > depth) : (i -= 1)
                    available[i] = word + (@as(u32, 1) << @intCast(32 - i));
            }
            self.entries[index] = .{
                .word = word,
                .symbol = @intCast(symbol),
                .length = @intCast(length),
            };
            index += 1;
        }
        std.mem.sortUnstable(Entry, self.entries, {}, Entry.lessThan);
        for (self.entries, 0..) |entry, i| {
            if (entry.length > 10) continue;
            var word: usize = @bitReverse(entry.word);
            while (word < self.fast.len) : (word += @as(usize, 1) <<
                @intCast(entry.length))
                self.fast[word] = @intCast(i);
        }
        const lookup = try bits.read(4);
        if (lookup > 2) return error.InvalidVorbis;
        if (lookup == 0) return self;
        const minimum = unpackFloat(try bits.read(32));
        const delta = unpackFloat(try bits.read(32));
        const valueBits: u6 = @intCast(try bits.read(4) + 1);
        const sequence = try bits.read(1) != 0;
        var values: usize = count * dimensions;
        if (lookup == 1) {
            values = 1;
            while (true) {
                var product: u64 = 1;
                for (0..dimensions) |_| {
                    product *= values + 1;
                    if (product > count) break;
                }
                if (product > count) break;
                values += 1;
            }
        }
        const raw = try memory.temp.alloc(u16, values);
        defer memory.temp.free(raw);
        for (raw) |*value| value.* = @intCast(try bits.read(valueBits));
        self.vectors = try allocator.alloc(f32, present * dimensions);
        for (self.entries, 0..) |entry, i| {
            var last: f32 = 0;
            var symbol = entry.symbol;
            for (0..dimensions) |j| {
                const offset = switch (lookup) {
                    1 => symbol % values,
                    2 => @as(usize, entry.symbol) * dimensions + j,
                    else => unreachable,
                };
                const value = @as(f32, @floatFromInt(raw[offset])) * delta +
                    minimum + last;
                self.vectors[i * dimensions + j] = value;
                if (sequence) last = value;
                if (lookup == 1) symbol = @intCast(symbol / values);
            }
        }
        return self;
    }

    /// 返回稀疏压缩后的条目索引，向量和标量共享查表过程。
    fn decode(self: *const Book, bits: *Bits) !usize {
        bits.fill(10);
        const fast = self.fast[@intCast(bits.value & 1023)];
        var index: usize = undefined;
        if (fast >= 0) {
            index = @intCast(fast);
        } else {
            if (self.entries.len == 0) return error.InvalidVorbis;
            bits.fill(32);
            const word = @bitReverse(@as(u32, @truncate(bits.value)));
            var low: usize = 0;
            var high = self.entries.len;
            while (low + 1 < high) {
                const middle = (low + high) / 2;
                if (self.entries[middle].word <= word) low = middle else high = middle;
            }
            index = low;
        }
        const entry = self.entries[index];
        if (bits.count < entry.length) return error.EndOfPacket;
        const mask = (@as(u64, 1) << entry.length) - 1;
        if (bits.value & mask != @bitReverse(entry.word)) return error.InvalidVorbis;
        bits.value >>= entry.length;
        bits.count -= entry.length;
        return index;
    }

    // 标量码本返回原始符号编号，而不是稀疏表中的存储位置。
    fn scalar(self: *const Book, bits: *Bits) !u32 {
        return self.entries[try self.decode(bits)].symbol;
    }

    // 向量码本直接返回初始化时展开的连续分量。
    fn vector(self: *const Book, bits: *Bits) ![]const f32 {
        const index = try self.decode(bits);
        return self.vectors[index * self.dimensions ..][0..self.dimensions];
    }
};

/// Vorbis 使用带独立指数的打包浮点数，并非 IEEE f32 位模式。
fn unpackFloat(value: u32) f32 {
    var number: f64 = @floatFromInt(value & 0x1fffff);
    if (value & 0x80000000 != 0) number = -number;
    const exponent = @as(i32, @intCast((value >> 21) & 1023)) - 788;
    return @floatCast(std.math.ldexp(number, exponent));
}

const FloorRead = struct { bits: *Bits, books: []Book };
const FloorClass = struct {
    size: usize = 0,
    bits: u2 = 0,
    master: usize = 0,
    books: [8]i16 = @splat(-1),
};

/// Floor 1 的折线节点、分类和相邻节点在初始化时确定。
const Floor = struct {
    partitions: []u8,
    classes: [16]FloorClass = @splat(.{}),
    multiplier: i32,
    x: []u16,
    order: []u8,
    neighbors: [][2]u8,
    books: []Book = &.{},

    // 解析分类和节点坐标，提前建立绘制顺序与预测相邻节点。
    fn init(allocator: std.mem.Allocator, read: FloorRead) !Floor {
        const bits = read.bits;
        const partitions = try allocator.alloc(u8, try bits.read(5));
        var self: Floor = .{
            .partitions = partitions,
            .multiplier = 0,
            .x = &.{},
            .order = &.{},
            .neighbors = &.{},
        };
        var classes: usize = 0;
        for (partitions) |*value| {
            value.* = @intCast(try bits.read(4));
            classes = @max(classes, @as(usize, value.*) + 1);
        }
        for (self.classes[0..classes]) |*class| {
            class.size = try bits.read(3) + 1;
            class.bits = @intCast(try bits.read(2));
            if (class.bits != 0) {
                class.master = try bits.read(8);
                if (class.master >= read.books.len) return error.InvalidVorbis;
            }
            for (class.books[0 .. @as(usize, 1) << class.bits]) |*book| {
                book.* = @as(i16, @intCast(try bits.read(8))) - 1;
                if (book.* >= read.books.len) return error.InvalidVorbis;
            }
        }
        self.multiplier = @intCast(try bits.read(2) + 1);
        const range: u6 = @intCast(try bits.read(4));
        var count: usize = 2;
        for (partitions) |class| count += self.classes[class].size;
        self.x = try allocator.alloc(u16, count);
        self.order = try allocator.alloc(u8, count);
        self.neighbors = try allocator.alloc([2]u8, count);
        self.x[0] = 0;
        self.x[1] = @as(u16, 1) << @intCast(range);
        for (self.x[2..]) |*x| x.* = @intCast(try bits.read(range));
        for (self.x, self.neighbors, self.order, 0..) |x, *pair, *order, i| {
            order.* = @intCast(i);
            if (i < 2) continue;
            var low: usize = 0;
            var high: usize = 1;
            for (self.x[0..i], 0..) |old, j| {
                if (old == x) return error.InvalidVorbis;
                if (old < x and old > self.x[low]) low = j;
                if (old > x and old < self.x[high]) high = j;
            }
            pair.* = .{ @intCast(low), @intCast(high) };
        }
        std.mem.sortUnstable(u8, self.order, self.x, lessX);
        return self;
    }

    fn lessX(x: []u16, a: u8, b: u8) bool {
        return x[a] < x[b];
    }

    /// 解码并预测折线高度；未激活节点用 -1 标记。
    fn decode(self: *const Floor, bits: *Bits, y: *[250]i32) !bool {
        if (try bits.read(1) == 0) return false;
        const range: i32 = switch (self.multiplier) {
            1 => 256,
            2 => 128,
            3 => 86,
            4 => 64,
            else => unreachable,
        };
        const width = bitCount(@intCast(range)) - 1;
        y[0] = @intCast(try bits.read(width));
        y[1] = @intCast(try bits.read(width));
        var offset: usize = 2;
        for (self.partitions) |index| {
            const class = self.classes[index];
            var value: u32 = if (class.bits != 0)
                try self.books[class.master].scalar(bits)
            else
                0;
            const mask = (@as(u32, 1) << class.bits) - 1;
            for (0..class.size) |_| {
                const book = class.books[value & mask];
                value >>= class.bits;
                y[offset] = 0;
                if (book >= 0)
                    y[offset] = @intCast(try self.books[@intCast(book)].scalar(bits));
                offset += 1;
            }
        }
        var active: [250]bool = @splat(false);
        active[0] = true;
        active[1] = true;
        for (2..self.x.len) |i| {
            const pair = self.neighbors[i];
            const low = pair[0];
            const high = pair[1];
            const difference = y[high] - y[low];
            const distance: i32 = self.x[high] - self.x[low];
            const step = @divTrunc(@as(i32, @intCast(@abs(difference))) *
                (self.x[i] - self.x[low]), distance);
            const predicted = if (difference < 0) y[low] - step else y[low] + step;
            const highRoom = range - predicted;
            const lowRoom = predicted;
            const room = @min(highRoom, lowRoom) * 2;
            const value = y[i];
            if (value == 0) {
                y[i] = predicted;
            } else {
                active[low] = true;
                active[high] = true;
                active[i] = true;
                if (value >= room) {
                    if (highRoom > lowRoom) {
                        y[i] = value - lowRoom + predicted;
                    } else {
                        y[i] = predicted - value + highRoom - 1;
                    }
                } else {
                    y[i] = if (value & 1 != 0)
                        predicted - @divTrunc(value + 1, 2)
                    else
                        predicted + @divTrunc(value, 2);
                }
            }
        }
        for (active[0..self.x.len], y[0..self.x.len]) |enabled, *value|
            if (!enabled) {
                value.* = -1;
            };
        return true;
    }

    /// 使用规范要求的整数折线步进，把 Floor 乘到 Residue 频谱上。
    fn apply(self: *const Floor, output: []f32, values: *const [250]i32) !void {
        var previous: usize = 0;
        for (self.order[1..]) |index| {
            if (values[index] < 0) continue;
            const x0: usize = self.x[previous];
            const x1: usize = self.x[index];
            const y0 = values[previous] * self.multiplier;
            const y1 = values[index] * self.multiplier;
            if (y0 < 0 or y0 > 255 or y1 < 0 or y1 > 255)
                return error.InvalidVorbis;
            const width: i32 = @intCast(x1 - x0);
            const difference = y1 - y0;
            const base = @divTrunc(difference, width);
            const extra = @as(i32, @intCast(@abs(difference))) -
                @as(i32, @intCast(@abs(base))) * width;
            const step = base + @as(i32, if (difference < 0) -1 else 1);
            var value = y0;
            var fraction: i32 = 0;
            var x = x0;
            while (x < @min(x1, output.len)) : (x += 1) {
                output[x] *= inverseDb()[@intCast(value)];
                fraction += extra;
                if (fraction >= width) {
                    fraction -= width;
                    value += step;
                } else value += base;
            }
            previous = index;
            if (x1 >= output.len) return;
        }
        const y = values[previous] * self.multiplier;
        if (y < 0 or y > 255) return error.InvalidVorbis;
        for (output[self.x[previous]..]) |*value|
            value.* *= inverseDb()[@intCast(y)];
    }
};

/// 此表取自 Vorbis 规范；保留规范的小数值以便与参考解码器比较。
fn inverseDb() *const [256]f32 {
    return &.{
        1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07,
        1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
        1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.1287530e-07,
        2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
        2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07,
        3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
        4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07,
        6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
        7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07,
        1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
        1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06,
        1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
        2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06,
        2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
        3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06,
        4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
        5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06,
        7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
        9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05,
        1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
        1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05,
        2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
        2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05,
        3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
        4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05,
        5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
        7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05,
        9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
        0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085,
        0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
        0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449,
        0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
        0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456,
        0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
        0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058,
        0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
        0.00092223983, 0.00098217216, 0.0010459992,  0.0011139742,
        0.0011863665,  0.0012634633,  0.0013455702,  0.0014330129,
        0.0015261382,  0.0016253153,  0.0017309374,  0.0018434235,
        0.0019632195,  0.0020908006,  0.0022266726,  0.0023713743,
        0.0025254795,  0.0026895994,  0.0028643847,  0.0030505286,
        0.0032487691,  0.0034598925,  0.0036847358,  0.0039241906,
        0.0041792066,  0.0044507950,  0.0047400328,  0.0050480668,
        0.0053761186,  0.0057254891,  0.0060975636,  0.0064938176,
        0.0069158225,  0.0073652516,  0.0078438871,  0.0083536271,
        0.0088964928,  0.009474637,   0.010090352,   0.010746080,
        0.011444421,   0.012188144,   0.012980198,   0.013823725,
        0.014722068,   0.015678791,   0.016697687,   0.017782797,
        0.018938423,   0.020169149,   0.021479854,   0.022875735,
        0.024362330,   0.025945531,   0.027631618,   0.029427276,
        0.031339626,   0.033376252,   0.035545228,   0.037855157,
        0.040315199,   0.042935108,   0.045725273,   0.048696758,
        0.051861348,   0.055231591,   0.058820850,   0.062643361,
        0.066714279,   0.071049749,   0.075666962,   0.080584227,
        0.085821044,   0.091398179,   0.097337747,   0.10366330,
        0.11039993,    0.11757434,    0.12521498,    0.13335215,
        0.14201813,    0.15124727,    0.16107617,    0.17154380,
        0.18269168,    0.19456402,    0.20720788,    0.22067342,
        0.23501402,    0.25028656,    0.26655159,    0.28387361,
        0.30232132,    0.32196786,    0.34289114,    0.36517414,
        0.38890521,    0.41417847,    0.44109412,    0.46975890,
        0.50028648,    0.53279791,    0.56742212,    0.60429640,
        0.64356699,    0.68538959,    0.72993007,    0.77736504,
        0.82788260,    0.88168307,    0.9389798,     1.0,
    };
}

/// 以 N/4 点复数 FFT 计算 DCT-IV，再按逆 MDCT 对称性展开。
const Mdct = struct {
    const Complex = struct { re: f32, im: f32 };

    size: usize,
    turns: []Complex,
    before: []Complex,
    after: []Complex,
    reverse: []u16,
    window: []f32,

    /// 初始化 FFT 和 Vorbis 窗口，所有表都由调用方的 arena 持有。
    fn init(allocator: std.mem.Allocator, size: usize) !Mdct {
        const count = size / 4;
        const turns = try allocator.alloc(Complex, count / 2);
        const before = try allocator.alloc(Complex, count);
        const after = try allocator.alloc(Complex, count);
        const reverse = try allocator.alloc(u16, count);
        const window = try allocator.alloc(f32, size / 2);
        for (turns, 0..) |*turn, i| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) /
                @as(f64, @floatFromInt(count));
            turn.* = .{ .re = @floatCast(@cos(angle)), .im = @floatCast(@sin(angle)) };
        }
        const bits: u4 = @intCast(@ctz(count));
        for (before, after, reverse, 0..) |*a, *b, *rev, i| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) /
                @as(f64, @floatFromInt(size));
            const offset = std.math.pi / (2 * @as(f64, @floatFromInt(size)));
            a.* = .{ .re = @floatCast(@cos(angle)), .im = @floatCast(@sin(angle)) };
            b.* = .{
                .re = @floatCast(@cos(angle + offset)),
                .im = @floatCast(@sin(angle + offset)),
            };
            rev.* = @bitReverse(@as(u16, @intCast(i))) >>
                @as(u4, @intCast(16 - @as(u5, bits)));
        }
        for (window, 0..) |*value, i| {
            const angle = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) /
                @as(f64, @floatFromInt(size));
            const sine = @sin(angle);
            value.* = @floatCast(@sin(std.math.pi / 2.0 * sine * sine));
        }
        return .{
            .size = size,
            .turns = turns,
            .before = before,
            .after = after,
            .reverse = reverse,
            .window = window,
        };
    }

    /// 工作缓冲需要 size/4 个复数，即 size/2 个 f32。
    fn run(self: Mdct, buffer: []f32, work: []Complex) void {
        const count = self.size / 4;
        const half = self.size / 2;
        // 偶数系数和倒序奇数系数组成一个复数序列。
        for (self.before, self.reverse, 0..) |turn, rev, i| {
            const even = buffer[i * 2];
            const odd = buffer[half - 1 - i * 2];
            work[rev] = .{
                .re = even * turn.re + odd * turn.im,
                .im = even * turn.im - odd * turn.re,
            };
        }
        var span: usize = 2;
        while (span <= count) : (span *= 2) {
            const step = count / span;
            var start: usize = 0;
            while (start < count) : (start += span) {
                for (0..span / 2) |i| {
                    const turn = self.turns[i * step];
                    const a = work[start + i];
                    const b = work[start + i + span / 2];
                    const re = b.re * turn.re - b.im * turn.im;
                    const im = b.re * turn.im + b.im * turn.re;
                    work[start + i] = .{ .re = a.re + re, .im = a.im + im };
                    work[start + i + span / 2] = .{
                        .re = a.re - re,
                        .im = a.im - im,
                    };
                }
            }
        }
        // 后旋转得到 DCT-IV，利用对称性直接写入完整的时域块。
        for (self.after, work[0..count], 0..) |turn, value, i| {
            store(buffer[0..self.size], i * 2, value.re * turn.re - value.im * turn.im);
            store(
                buffer[0..self.size],
                half - 1 - i * 2,
                value.re * turn.im + value.im * turn.re,
            );
        }
    }

    /// 将一个 DCT-IV 系数展开到逆 MDCT 的两个对称位置。
    fn store(buffer: []f32, index: usize, value: f32) void {
        const half = buffer.len / 2;
        buffer[half * 3 / 2 - 1 - index] = -value;
        if (index < half / 2) {
            buffer[half * 3 / 2 + index] = -value;
        } else {
            buffer[index - half / 2] = value;
        }
    }
};
