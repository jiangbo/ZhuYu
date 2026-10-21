//! MIDI 0/1 音乐播放器，内置第 58 号 Fat Man 两运算器音色。
//! 按需合成 PCM；同一个播放器的控制和采样调用必须由调用方同步。
//!
//! FM 包络、波形参考 Opal，Win9x 音高和音量模型参考 libADLMIDI。
//! 来源、版权和 MIT 许可见仓库根目录 licenses/midi.txt。
const std = @import("std");

/// 已解析的音乐和播放状态。init 后调用 fillSamples，结束后调用 deinit。
pub const Player = struct {
    allocator: std.mem.Allocator,
    events: []Event,
    sampleRate: u32,
    frame: u64 = 0,
    eventIndex: usize = 0,
    tailFrame: ?u64 = null,
    channels: [16]Channel = @splat(.{}),
    // 四片 OPL3 均用于双运算器音色，共 72 个声部。
    voices: [72]Voice = @splat(.{}),
    clock: Clock = .{},
    samplePhase: u64 = 0,
    previous: [2]f32 = .{ 0, 0 },
    current: [2]f32 = .{ 0, 0 },
    masterVolume: u32 = 127,

    /// 解析全部轨道并转换事件时间；不保留输入数据，音频线程不分配内存。
    pub fn init(
        allocator: std.mem.Allocator,
        data: []const u8,
        sampleRate: u32,
    ) !Player {
        std.debug.assert(sampleRate > 0);
        var reader: Reader = .{ .data = data };
        if (!std.mem.eql(u8, try reader.take(4), "MThd")) {
            return error.InvalidMidi;
        }
        const headerSize = try reader.number(u32);
        if (headerSize < 6) return error.InvalidMidi;
        const format = try reader.number(u16);
        const tracks = try reader.number(u16);
        const division = try reader.number(u16);
        if (format > 1) return error.UnsupportedMidiFormat;
        if (tracks == 0 or (format == 0 and tracks != 1)) {
            return error.InvalidMidi;
        }
        // SMPTE 时间制与按拍计时是两套格式，当前明确只接收按拍计时。
        if (division == 0 or division & 0x8000 != 0) {
            return error.UnsupportedTimeDivision;
        }
        _ = try reader.take(headerSize - 6);

        var events: std.ArrayList(Event) = .empty;
        errdefer events.deinit(allocator);
        var endTick: u64 = 0;
        for (0..tracks) |_| {
            if (!std.mem.eql(u8, try reader.take(4), "MTrk")) {
                return error.InvalidMidi;
            }
            const size = try reader.number(u32);
            var track: Reader = .{ .data = try reader.take(size) };
            var tick: u64 = 0;
            var running: u8 = 0;
            var ended = false;
            while (track.index < track.data.len) {
                tick += try track.variable();
                var status = try track.byte();
                if (status < 0x80) {
                    if (running == 0) return error.InvalidMidi;
                    track.index -= 1;
                    status = running;
                }
                var event: Event = .{ .time = tick, .status = status };
                if (status < 0xf0) {
                    running = status;
                    event.a = try track.value();
                    if (status & 0xe0 != 0xc0) event.b = try track.value();
                } else if (status == 0xff) {
                    const kind = try track.byte();
                    const bytes = try track.take(try track.variable());
                    if (kind == 0x2f) {
                        if (bytes.len != 0) return error.InvalidMidi;
                        ended = true;
                        break;
                    }
                    if (kind != 0x51) continue;
                    if (bytes.len != 3) return error.InvalidMidi;
                    event.value = std.mem.readInt(u24, bytes[0..3], .big);
                    if (event.value == 0) return error.InvalidMidi;
                } else if (status == 0xf0 or status == 0xf7) {
                    running = 0;
                    const bytes = try track.take(try track.variable());
                    // 标准 GM 重置和通用主音量是普通 MIDI 常用的 SysEx。
                    if (bytes.len == 5 and bytes[0] == 0x7e and
                        bytes[2] == 9 and bytes[4] == 0xf7)
                    {
                        event.status = 0xf0;
                        event.value = 0;
                    } else if (bytes.len == 7 and bytes[0] == 0x7f and
                        bytes[2] == 4 and bytes[3] == 1 and bytes[6] == 0xf7)
                    {
                        if (bytes[4] >= 128 or bytes[5] >= 128) {
                            return error.InvalidMidi;
                        }
                        event.status = 0xf0;
                        event.value = 1;
                        event.a = bytes[5];
                    } else continue;
                } else return error.InvalidMidi;
                try events.append(allocator, event);
            }
            if (!ended) return error.InvalidMidi;
            endTick = @max(endTick, tick);
        }
        // 稳定排序保留同一时刻原有的事件顺序，尤其是换乐器和音符事件。
        std.mem.sort(Event, events.items, {}, Event.lessThan);
        try events.append(allocator, .{ .time = endTick, .status = 0xfe });
        var tick: u64 = 0;
        var frame: u64 = 0;
        var remainder: u64 = 0;
        var tempo: u64 = 500000;
        const denominator = @as(u64, division) * 1000000;
        for (events.items) |*event| {
            const span = @as(u128, event.time - tick) * tempo * sampleRate;
            const duration = span + remainder;
            tick = event.time;
            frame += @intCast(duration / denominator);
            remainder = @intCast(duration % denominator);
            event.time = frame;
            if (event.status == 0xff) tempo = event.value;
        }
        return .{
            .allocator = allocator,
            .events = try events.toOwnedSlice(allocator),
            .sampleRate = sampleRate,
        };
    }

    /// 释放解析后的事件；调用前先停止音频线程使用此播放器。
    pub fn deinit(self: *Player) void {
        self.allocator.free(self.events);
        self.* = undefined;
    }

    /// 从头播放并清除踏板、余音和通道控制器。
    pub fn reset(self: *Player) void {
        self.* = .{
            .allocator = self.allocator,
            .events = self.events,
            .sampleRate = self.sampleRate,
        };
    }

    /// 填充交错的单/双声道 f32，返回实际生成的帧数，结束时可以少于容量。
    pub fn fillSamples(self: *Player, buffer: []f32, channels: i32) i32 {
        std.debug.assert(channels == 1 or channels == 2);
        const count: usize = @intCast(channels);
        std.debug.assert(buffer.len % count == 0);
        var frame: usize = 0;
        while (frame < buffer.len / count) : (frame += 1) {
            while (self.eventIndex < self.events.len and
                self.events[self.eventIndex].time <= self.frame)
            {
                self.handle(self.events[self.eventIndex]);
                self.eventIndex += 1;
            }
            if (self.tailFrame) |end| {
                if (self.frame >= end) break;
            }
            // 芯片按 49716 Hz 运行，再线性重采样到实际音频设备的采样率。
            while (self.samplePhase >= self.sampleRate) {
                self.previous = self.current;
                self.current = self.sample();
                self.samplePhase -= self.sampleRate;
            }
            const fraction = @as(f32, @floatFromInt(self.samplePhase)) /
                @as(f32, @floatFromInt(self.sampleRate));
            var output: [2]f32 = undefined;
            for (&output, 0..) |*value, side| {
                value.* = self.previous[side] +
                    (self.current[side] - self.previous[side]) * fraction;
            }
            if (count == 1) {
                buffer[frame] = (output[0] + output[1]) * 0.5;
            } else {
                buffer[frame * 2] = output[0];
                buffer[frame * 2 + 1] = output[1];
            }
            self.samplePhase += 49716;
            self.frame += 1;
        }
        return @intCast(frame);
    }

    /// 分发普通 MIDI 通道事件；未使用的文本、标记等元事件已在解析时跳过。
    fn handle(self: *Player, event: Event) void {
        const index = event.status & 15;
        const channel = &self.channels[index];
        switch (event.status & 0xf0) {
            0x80 => self.noteOff(index, event.a),
            0x90 => {
                if (event.b == 0) self.noteOff(index, event.a) else self.noteOn(event);
            },
            0xb0 => self.control(event),
            0xc0 => channel.program = event.a,
            0xe0 => {
                channel.bend = @as(i32, event.a) + @as(i32, event.b) * 128 - 8192;
                self.update(index);
            },
            0xf0 => {
                if (event.status == 0xfe) {
                    // 文件结束释放全部音符，按当前音色的释放时间保留余音。
                    var tail: u64 = self.sampleRate / 10;
                    for (&self.voices) |*voice| {
                        if (!voice.active) continue;
                        voice.key = false;
                        const ms = voice.instrument.releaseMs();
                        tail = @max(tail, (@as(u64, ms) + 100) *
                            self.sampleRate / 1000);
                    }
                    self.tailFrame = self.frame + tail;
                } else if (event.status == 0xf0) {
                    if (event.value == 0) {
                        self.channels = @splat(.{});
                        self.voices = @splat(.{});
                        self.masterVolume = 127;
                    } else {
                        self.masterVolume = event.a;
                        for (0..16) |ch| self.update(ch);
                    }
                }
            },
            else => {},
        }
    }

    /// 为新音符装入音色，优先使用空闲或已释放的声部。
    fn noteOn(self: *Player, event: Event) void {
        const ch = event.status & 15;
        var program: usize = self.channels[ch].program;
        if (ch == 9) program = @as(usize, event.a) + 128;
        const instrument = Instrument.get(program);
        if (instrument.bytes[39] & 4 != 0) return;
        var best: usize = 0;
        for (self.voices, 0..) |voice, i| {
            if (!voice.active) {
                best = i;
                break;
            }
            const old = self.voices[best];
            if ((!voice.key and old.key) or
                (voice.key == old.key and voice.age < old.age)) best = i;
        }
        const voice = &self.voices[best];
        voice.* = .{
            .active = true,
            .key = true,
            .held = true,
            .channel = ch,
            .note = event.a,
            .velocity = event.b,
            .age = self.frame,
            .instrument = instrument,
        };
        // WOPL 存储顺序为载波、调制波；计算顺序从调制波开始。
        for ([_]usize{ 1, 0 }, 0..) |source, target| {
            const bytes = instrument.bytes[42 + source * 5 ..][0..5];
            voice.ops[target] = .{
                .flags = bytes[0],
                .level = bytes[1],
                .rates = bytes[2],
                .release = bytes[3],
                .wave = @intCast(bytes[4]),
            };
        }
        voice.update(self.channels[ch], self.masterVolume);
    }

    /// 松开按键；延音和持续音踏板可以继续保持声部。
    fn noteOff(self: *Player, ch: usize, note: u8) void {
        var first: ?*Voice = null;
        for (&self.voices) |*voice| {
            if (!voice.active or voice.channel != ch or
                voice.note != note or !voice.held) continue;
            if (first == null or voice.age < first.?.age) first = voice;
        }
        // 同音重叠时一次 Note Off 只释放最早分配的一个音符。
        if (first) |voice| {
            voice.held = false;
            voice.key = self.channels[ch].sustain or voice.sostenuto;
        }
    }

    /// 应用 MIDI 常用控制器、弯音范围及踏板。
    fn control(self: *Player, event: Event) void {
        const ch = event.status & 15;
        const channel = &self.channels[ch];
        switch (event.a) {
            1 => channel.modulation = event.b,
            7 => channel.volume = event.b,
            10 => channel.pan = event.b,
            11 => channel.expression = event.b,
            64 => {
                channel.sustain = event.b >= 64;
                for (&self.voices) |*voice| {
                    if (!channel.sustain and voice.channel == ch and
                        !voice.held and !voice.sostenuto) voice.key = false;
                }
            },
            66 => {
                const down = event.b >= 64;
                if (down != channel.sostenuto) {
                    for (&self.voices) |*voice| {
                        if (!voice.active or voice.channel != ch) continue;
                        voice.sostenuto = down and voice.held;
                        if (!down and !voice.held and !channel.sustain) {
                            voice.key = false;
                        }
                    }
                }
                channel.sostenuto = down;
            },
            100 => channel.rpnLow = event.b,
            101 => channel.rpnHigh = event.b,
            98, 99 => {
                channel.rpnHigh = 127;
                channel.rpnLow = 127;
            },
            6 => {
                if (channel.rpnHigh == 0 and channel.rpnLow == 0) {
                    channel.bendRange = event.b;
                }
            },
            38 => {
                if (channel.rpnHigh == 0 and channel.rpnLow == 0) {
                    channel.bendCents = event.b;
                }
            },
            120 => {
                for (&self.voices) |*voice| {
                    if (voice.channel == ch) voice.* = .{};
                }
            },
            121 => {
                const program = channel.program;
                const volume = channel.volume;
                const pan = channel.pan;
                channel.* = .{ .program = program, .volume = volume, .pan = pan };
                for (&self.voices) |*voice| {
                    if (voice.channel != ch) continue;
                    voice.sostenuto = false;
                    voice.key = voice.held;
                }
            },
            123, 124, 125, 126, 127 => {
                for (&self.voices) |*voice| {
                    if (voice.channel != ch or !voice.held) continue;
                    voice.held = false;
                    voice.key = channel.sustain or voice.sostenuto;
                }
            },
            else => return,
        }
        self.update(ch);
    }

    /// 控制器变化立即影响正在发声的音符。
    fn update(self: *Player, ch: usize) void {
        for (&self.voices) |*voice| {
            if (voice.active and voice.channel == ch) {
                voice.update(self.channels[ch], self.masterVolume);
            }
        }
    }

    /// 生成一帧芯片采样，并推进全部声部共用的包络和 LFO 时钟。
    fn sample(self: *Player) [2]f32 {
        var mix: [2]i32 = .{ 0, 0 };
        for (&self.voices) |*voice| {
            if (!voice.active) continue;
            const value = voice.sample(self.clock);
            mix[0] += @divTrunc(value * voice.left, 256);
            mix[1] += @divTrunc(value * voice.right, 256);
        }
        self.clock.next();
        // 第 58 号音色固定增加约 3.5 dB，保留试听时选定的音量。
        return .{
            std.math.clamp(
                @as(f32, @floatFromInt(mix[0])) / 32768 * 1.5,
                -1,
                1,
            ),
            std.math.clamp(
                @as(f32, @floatFromInt(mix[1])) / 32768 * 1.5,
                -1,
                1,
            ),
        };
    }
};

// 事件在解析阶段使用 tick，排序完成后原地替换成输出采样帧。
const Event = struct {
    time: u64,
    status: u8,
    a: u8 = 0,
    b: u8 = 0,
    value: u32 = 0,

    // 只比较时间，稳定排序负责保留同一时刻的原有顺序。
    fn lessThan(_: void, a: Event, b: Event) bool {
        return a.time < b.time;
    }
};

// MIDI 字节读取器，截断、非法数据和超长变长整数直接返回错误。
const Reader = struct {
    data: []const u8,
    index: usize = 0,

    // 消费指定字节，文件截断时直接报错。
    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.data.len - self.index) return error.InvalidMidi;
        const data = self.data[self.index..][0..count];
        self.index += count;
        return data;
    }

    // 读取一个原始字节。
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    // 通道事件的数据字节只能使用低七位。
    fn value(self: *Reader) !u8 {
        const result = try self.byte();
        if (result >= 128) return error.InvalidMidi;
        return result;
    }

    // MIDI 文件的定长数值使用大端字节序。
    fn number(self: *Reader, comptime T: type) !T {
        const data = try self.take(@sizeOf(T));
        return std.mem.readInt(T, data[0..@sizeOf(T)], .big);
    }

    // MIDI 变长整数最多四字节，每字节提供七位数据。
    fn variable(self: *Reader) !u32 {
        var result: u32 = 0;
        for (0..4) |_| {
            const part = try self.byte();
            result = (result << 7) | (part & 127);
            if (part < 128) return result;
        }
        return error.InvalidMidi;
    }
};

// 16 个通道各自保存 MIDI 控制器，不将 MIDI 通道和合成声部混为一谈。
const Channel = struct {
    program: u8 = 0,
    volume: u32 = 100,
    expression: u32 = 127,
    pan: u32 = 64,
    modulation: u8 = 0,
    sustain: bool = false,
    sostenuto: bool = false,
    bend: i32 = 0,
    bendRange: u8 = 2,
    bendCents: u8 = 0,
    rpnHigh: u8 = 127,
    rpnLow: u8 = 127,
};

// 固定完整 GM 音色库：128 个旋律音色和 128 个打击乐条目。
const Instrument = struct {
    bytes: *const [66]u8 = undefined,

    // 直接访问固定音色库中的完整条目，不创建运行时音色副本。
    fn get(index: usize) Instrument {
        const bank = @embedFile("fatman-2op.wopl");
        const offset = 87 + index * 66;
        return .{ .bytes = bank[offset..][0..66] };
    }

    // 音色自带的释放时长用于保留文件末尾的余音。
    fn releaseMs(self: Instrument) u16 {
        return std.mem.readInt(u16, self.bytes[64..66], .big);
    }
};

// 一个独立音符，两个运算器共用音高，载波决定最终输出和音量控制。
const Voice = struct {
    active: bool = false,
    key: bool = false,
    held: bool = false,
    sostenuto: bool = false,
    channel: usize = 0,
    note: u8 = 0,
    velocity: u32 = 0,
    age: u64 = 0,
    instrument: Instrument = .{},
    ops: [2]Operator = @splat(.{}),
    freq: u32 = 0,
    block: u5 = 0,
    left: i32 = 256,
    right: i32 = 256,
    modulation: u8 = 0,

    /// 从 WOPL 的连接位确定哪些运算器直接输出声音。
    fn carriers(self: Voice) [2]bool {
        return .{ self.instrument.bytes[40] & 1 != 0, true };
    }

    /// 按 Win9x SB16 模型更新音高、载波音量和连续声像。
    fn update(self: *Voice, channel: Channel, master: u32) void {
        const bytes = self.instrument.bytes;
        var note: f64 = @floatFromInt(self.note);
        if (self.channel == 9) {
            note = @floatFromInt(bytes[38]);
        }
        const range = @as(f64, @floatFromInt(channel.bendRange)) +
            @as(f64, @floatFromInt(channel.bendCents)) / 100;
        note += @as(f64, @floatFromInt(channel.bend)) * range / 8192;
        self.pitch(@max(note, 0));
        self.modulation = channel.modulation;
        // 等功率声像使居中时两侧各约 0.707，与网页的软声像保持一致。
        const angle = @as(f64, @floatFromInt(channel.pan)) * std.math.pi / 254;
        self.left = @intFromFloat(@cos(angle) * 256);
        self.right = @intFromFloat(@sin(angle) * 256);
        const table = [_]u32{
            80, 63, 40, 36, 32, 28, 23, 21,
            19, 17, 15, 14, 13, 12, 11, 10,
            9,  8,  7,  6,  5,  5,  4,  4,
            3,  3,  2,  2,  1,  1,  0,  0,
        };
        const volume = channel.volume * channel.expression * master / 16129;
        const attenuation = table[volume >> 2] + table[self.velocity >> 2];
        const output = self.carriers();
        for (&self.ops, output) |*op, carrier| {
            const level = @as(u32, op.level & 63);
            op.attenuation = @as(u32, @min(63, level +
                if (carrier) attenuation else 0)) * 4;
        }
    }

    /// Win9x 的十二音阶表及弯音近似，保持这套音色原有的调音。
    fn pitch(self: *Voice, tone: f64) void {
        var note: u32 = @intFromFloat(if (tone >= 12) tone - 12 else tone);
        var fraction = tone - @trunc(tone);
        if (fraction > 0.5) {
            note += 1;
            fraction -= 1;
        }
        const table = [_]u32{
            0xab7, 0xb5a,  0xc07,  0xcbe,  0xd80,  0xe4d,
            0xf27, 0x100e, 0x1102, 0x1205, 0x1318, 0x143a,
        };
        const octave = note / 12;
        var freq: i64 = table[note % 12];
        if (octave < 5) {
            freq >>= @intCast(5 - octave);
        } else {
            freq <<= @intCast(octave - 5);
        }
        const bend: i32 = @as(i32, @intFromFloat(fraction * 4096)) * 4;
        const diff = if (bend > 0) (bend * 31) >> 8 else (-bend * 27) >> 8;
        const delta = (freq * diff) >> 15;
        freq += if (bend > 0) delta else -delta;
        freq *= 2;
        self.block = 1;
        while (freq > 1023) {
            freq >>= 1;
            self.block += 1;
        }
        self.freq = @intCast(freq);
    }

    /// 按两运算器算法连接运算器，释放完成后归还声部。
    fn sample(self: *Voice, clock: Clock) i32 {
        const a = self.instrument.bytes[40];
        const feedback: u3 = @intCast((a >> 1) & 7);
        var freq = self.freq;
        if (self.modulation != 0) {
            // 调制轮控制额外颤音，周期约 6 Hz；音色自身的颤音另行处理。
            const phase = @as(f64, @floatFromInt(clock.tick % 8286)) /
                8286 * 2 * std.math.pi;
            const offset = @sin(phase) * @as(f64, @floatFromInt(freq)) *
                @as(f64, @floatFromInt(self.modulation)) / 127 * 0.0145;
            freq = @intCast(@as(i64, freq) + @as(i64, @intFromFloat(offset)));
        }
        const tone: Tone = .{ .freq = freq, .block = self.block, .key = self.key };
        const op0 = self.ops[0].sample(clock, tone, .{ .feedback = feedback });
        const op1 = self.ops[1].sample(clock, tone, .{
            .modulation = if (a & 1 == 0) op0 else 0,
        });
        const result = op1 + if (a & 1 != 0) op0 else @as(i32, 0);
        if (!self.key) {
            const output = self.carriers();
            var silent = true;
            for (self.ops, output) |op, carrier| {
                if (carrier and op.envelope < 511) silent = false;
            }
            if (silent) self.active = false;
        }
        return result;
    }
};

// 每个运算器共用的音高信息，避免重复存储通道状态。
const Tone = struct { freq: u32, block: u5, key: bool };

// 全部声部共用芯片包络时钟及硬件 LFO，保持不同音符之间的调制相位。
const Clock = struct {
    tick: u64 = 0,
    timer: u64 = 0,
    state: u32 = 0,
    add: u32 = 0,
    low: u2 = 0,
    remainder: bool = false,
    tremolo: u32 = 0,
    vibrato: u3 = 0,

    // 每个芯片采样推进一次硬件 LFO 和包络计数器。
    fn next(self: *Clock) void {
        self.tick +%= 1;
        const position = (self.tick / 64) % 210;
        const triangle = if (position < 105) position else 210 - position;
        self.tremolo = @intCast(triangle >> 4);
        self.vibrato = @truncate(self.tick / 1024);
        if (self.state != 0) {
            const shift = @ctz(self.timer);
            self.add = if (shift > 12) 0 else @as(u32, shift) + 1;
            self.low = @truncate(self.timer);
        }
        if (self.remainder or self.state != 0) {
            self.remainder = self.timer == 0xfffffffff;
            self.timer = if (self.remainder) 0 else self.timer + 1;
        }
        self.state ^= 1;
    }
};

// OPL 运算器：对数波形、指数衰减和按芯片时钟运行的四阶段包络。
const Operator = struct {
    flags: u8 = 0,
    level: u8 = 0,
    rates: u8 = 0,
    release: u8 = 0,
    wave: u2 = 0,
    attenuation: u32 = 0,
    phase: u32 = 0,
    envelope: u32 = 511,
    stage: enum { attack, decay, sustain, release } = .release,
    output: i32 = 0,
    previous: i32 = 0,

    const Input = struct { modulation: i32 = 0, feedback: u3 = 0 };

    /// 先计算当前包络输出，再推进相位和包络，保持 OPL 的时序。
    fn sample(self: *Operator, clock: Clock, tone: Tone, input: Input) i32 {
        const kslRom = [_]i32{
            0,  32, 40, 45, 48, 51, 53, 55,
            56, 58, 59, 60, 61, 62, 63, 64,
        };
        const kslShift = [_]u5{ 8, 1, 2, 0 };
        const ksl = @max(0, kslRom[tone.freq >> 6] * 4 -
            (8 - @as(i32, tone.block)) * 32);
        const envelope = self.envelope + self.attenuation +
            (@as(u32, @intCast(ksl)) >> kslShift[self.level >> 6]) +
            (if (self.flags & 0x80 != 0) clock.tremolo else 0);
        const reset = self.stepEnvelope(clock, tone);
        var freq: i32 = @intCast(tone.freq);
        if (self.flags & 0x40 != 0) {
            var range: i32 = @intCast((tone.freq >> 7) & 7);
            if (clock.vibrato & 3 == 0) {
                range = 0;
            } else if (clock.vibrato & 1 != 0) {
                range >>= 1;
            }
            range >>= 1;
            freq += if (clock.vibrato & 4 != 0) -range else range;
        }
        const multipliers = [_]u32{
            1,  2,  4,  6,  8,  10, 12, 14,
            16, 18, 20, 20, 24, 24, 30, 30,
        };
        const phase: i32 = @intCast((self.phase >> 9) & 1023);
        if (reset) self.phase = 0;
        const base = (@as(u32, @intCast(freq)) << tone.block) >> 1;
        self.phase +%= (base * multipliers[self.flags & 15]) >> 1;
        var modulation = input.modulation;
        if (input.feedback != 0) {
            modulation += (self.output + self.previous) >>
                @as(u5, 9 - @as(u5, input.feedback));
        }
        self.previous = self.output;
        self.output = waveSample(self.wave, @intCast(@mod(phase +
            modulation, 1024)), envelope);
        return self.output;
    }

    /// OPL 包络速率同时受键位、KSR 和全局包络计数器控制。
    fn stepEnvelope(self: *Operator, clock: Clock, tone: Tone) bool {
        const reset = tone.key and self.stage == .release;
        const rate: u32 = if (reset) self.rates >> 4 else switch (self.stage) {
            .attack => self.rates >> 4,
            .decay => self.rates & 15,
            .sustain => if (self.flags & 0x20 != 0) 0 else self.release & 15,
            .release => self.release & 15,
        };
        var scale = (@as(u32, tone.block) << 1) | (tone.freq >> 9);
        if (self.flags & 0x10 == 0) scale >>= 2;
        const fullRate = scale + rate * 4;
        const high = @min(15, fullRate >> 2);
        const low = fullRate & 3;
        var shift: u5 = 0;
        if (rate != 0) {
            if (high < 12) {
                if (clock.state != 0) {
                    shift = switch (high + clock.add) {
                        12 => 1,
                        13 => @intCast((low >> 1) & 1),
                        14 => @intCast(low & 1),
                        else => 0,
                    };
                }
            } else {
                const steps = [_][4]u5{
                    .{ 0, 0, 0, 0 }, .{ 1, 0, 0, 0 },
                    .{ 1, 0, 1, 0 }, .{ 1, 1, 1, 0 },
                };
                shift = @intCast((high & 3) + steps[low][clock.low]);
                if (shift & 4 != 0) shift = 3;
                if (shift == 0) shift = @intCast(clock.state);
            }
        }
        var level: i32 = @intCast(self.envelope);
        var increment: i32 = 0;
        const off = self.envelope & 0x1f8 == 0x1f8;
        if (reset and high == 15) level = 0;
        if (self.stage != .attack and !reset and off) level = 511;
        switch (self.stage) {
            .attack => {
                if (level == 0) {
                    self.stage = .decay;
                } else if (tone.key and shift > 0 and high != 15) {
                    increment = ~level >> (4 - shift);
                }
            },
            .decay => {
                var sustain: u32 = self.release >> 4;
                if (sustain == 15) sustain = 31;
                if (level >> 4 == sustain) {
                    self.stage = .sustain;
                } else if (!off and !reset and shift > 0) {
                    increment = @as(i32, 1) << (shift - 1);
                }
            },
            .sustain, .release => {
                if (!off and !reset and shift > 0) {
                    increment = @as(i32, 1) << (shift - 1);
                }
            },
        }
        self.envelope = @intCast((level + increment) & 511);
        if (reset) self.stage = .attack;
        if (!tone.key) self.stage = .release;
        return reset;
    }
};

/// 固定音色库使用的四种波形，ROM 表和运算方式参考 Opal。
fn waveSample(wave: u2, phase: u32, envelope: u32) i32 {
    const logSin = comptime blk: {
        @setEvalBranchQuota(10000);
        var table: [256]u32 = undefined;
        for (&table, 0..) |*value, i| {
            const angle = (@as(f64, @floatFromInt(i)) + 0.5) *
                std.math.pi / 512;
            value.* = @intFromFloat(@round(-@log2(@sin(angle)) * 256));
        }
        break :blk table;
    };
    const exp = comptime blk: {
        @setEvalBranchQuota(10000);
        var table: [256]u32 = undefined;
        for (&table, 0..) |*value, i| {
            const power = @as(f64, @floatFromInt(255 - i)) / 256;
            value.* = @intFromFloat(@round(@exp2(power) * 1024));
        }
        break :blk table;
    };
    var level: u32 = 0;
    var negative = false;
    const sine = logSin[
        if (phase & 0x100 != 0)
            (phase & 255) ^ 255
        else
            phase & 255
    ];
    switch (wave) {
        0 => {
            level = sine;
            negative = phase & 0x200 != 0;
        },
        1 => level = if (phase & 0x200 != 0) 0x1000 else sine,
        2 => level = sine,
        3 => level = if (phase & 0x100 != 0) 0x1000 else logSin[phase & 255],
    }
    level = @min(0x1fff, level + envelope * 8);
    const value: i32 = @intCast((exp[level & 255] << 1) >>
        @as(u5, @intCast(level >> 8)));
    return if (negative) ~value else value;
}
