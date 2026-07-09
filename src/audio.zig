const std = @import("std");
const sk = @import("sokol");
const assets = @import("assets.zig");
const stbAudio = @import("internal/c.zig").stbAudio;

var mutex: std.Io.Mutex = .init;
pub var paused: std.atomic.Value(bool) = .init(false);

pub fn init(sampleRate: u32, soundBuffer: []Sound) void {
    sounds = soundBuffer;
    for (sounds) |*sound| sound.state = .stopped;

    // 启动音频线程
    sk.audio.setup(.{
        .num_channels = 2,
        .sample_rate = @intCast(sampleRate),
        .stream_cb = audioCallback,
        .logger = .{ .func = sk.log.func },
        .allocator = @bitCast(assets.memory.skAllocator),
    });
}

pub fn deinit() void {
    setMusicState(.stopped);
    stopSounds();
    sk.audio.shutdown();
}

pub fn setVolume(volume: f32) void {
    const value = std.math.clamp(volume, 0.0, 1.0);
    musicVolume.store(value, .release);
    soundVolume.store(value, .release);
}

pub fn changeMusicVolume(amount: f32) void {
    const current = musicVolume.load(.acquire);
    const next = std.math.clamp(current + amount, 0, 1);
    musicVolume.store(next, .release);
}

pub fn changeSoundVolume(amount: f32) void {
    const current = soundVolume.load(.acquire);
    const next = std.math.clamp(current + amount, 0, 1);
    soundVolume.store(next, .release);
}

pub var musicVolume: std.atomic.Value(f32) = .init(1);
var music: Music = .{ .state = .stopped };

pub const StateEnum = enum { playing, paused, stopped };

pub const Music = struct {
    source: *stbAudio.Audio = undefined,
    state: StateEnum = .playing,
    loop: bool = true,
};

pub fn playMusic(path: [:0]const u8) void {
    playMusicOption(path, true);
}

pub fn playMusicOption(path: [:0]const u8, loop: bool) void {
    if (!sk.audio.isvalid()) return;
    const source = assets.loadMusic(path, loop);
    if (source == null) return;

    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);

    stbAudio.reset(source.?);
    music = .{ .source = source.?, .loop = loop };
}

pub fn setMusicState(state: StateEnum) void {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    music.state = state;
}

pub const Sound = struct {
    pub const Option = struct {
        loop: bool = false,
        left: f32 = 1,
        right: f32 = 1,
    };
    samples: []const f32 = &.{},
    option: Option = .{},

    index: usize = 0,
    channels: u8 = 0,
    state: StateEnum = .playing,
};

pub var soundVolume: std.atomic.Value(f32) = .init(1);
var sounds: []Sound = &.{};

pub fn playSound(path: [:0]const u8) void {
    _ = playSoundOption(path, .{});
}

pub fn playSoundOption(path: [:0]const u8, option: Sound.Option) ?usize {
    if (@import("builtin").is_test) return null;
    if (!sk.audio.isvalid()) return null;

    const left = std.math.clamp(option.left, 0.0, 1.0);
    const right = std.math.clamp(option.right, 0.0, 1.0);
    const sound = assets.loadSound(path, .{
        .loop = option.loop,
        .left = left,
        .right = right,
    });
    if (sound.channels == 0) return null;

    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);

    const index = allocSoundIndex();
    sounds[index] = .{
        .samples = sound.samples,
        .channels = sound.channels,
        .option = .{ .loop = option.loop, .left = left, .right = right },
    };
    return index;
}

pub fn stopSounds() void {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    for (sounds) |*s| s.state = .stopped;
}

fn allocSoundIndex() usize {
    for (sounds, 0..) |*sound, index| {
        if (sound.state == .stopped) return index;
    }
    @panic("too many audio sound");
}

export fn audioCallback(b: [*c]f32, frames: i32, channels: i32) void {
    const len = @as(usize, @intCast(frames * channels));
    const buffer = b[0..len];
    @memset(buffer, 0);
    if (paused.load(.acquire)) return;

    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);

    if (music.state == .playing) fillMusic(buffer, channels);
    fillSound(buffer);
}

fn fillMusic(buffer: []f32, channels: i32) void {
    // 先处理音乐，目前只支持播放一个音乐。
    const volume = musicVolume.load(.acquire);
    var len: usize = 0; // 存储填充的长度
    // 因为有可能循环播放，所以循环添加，直到缓冲区填满。
    while (music.state == .playing) {
        const source = music.source;
        const count = stbAudio.fillSamples(source, buffer[len..], channels);
        len += @as(usize, @intCast(count * channels));

        if (len == buffer.len) break;
        if (music.loop) stbAudio.reset(source) else music.state = .stopped;
    }
    // 填充音乐完成，设置音乐的音量
    for (buffer[0..len]) |*sample| sample.* *= volume;
}

fn fillSound(buffer: []f32) void {
    const volume = soundVolume.load(.acquire);

    // 填充声音
    for (sounds) |*sound| {
        var len: usize = 0;
        if (sound.state != .playing) continue;
        while (len < buffer.len and sound.state == .playing) {
            len += mixSamples(buffer[len..], sound, volume);
        }
    }
}

fn mixSamples(buffer: []f32, sound: *Sound, volume: f32) usize {
    const len = if (sound.channels == 1)
        mixMonoSamples(buffer, sound, volume)
    else if (sound.channels == 2)
        mixStereoSamples(buffer, sound, volume)
    else
        std.debug.panic("unsupported channels: {d}", .{sound.channels});

    if (sound.index == sound.samples.len) {
        if (sound.option.loop) sound.index = 0 else sound.state = .stopped;
    }

    return len;
}

fn mixStereoSamples(dstBuffer: []f32, sound: *Sound, volume: f32) usize {
    const srcBuffer = sound.samples[sound.index..];
    const len = @min(dstBuffer.len, srcBuffer.len) / 2 * 2;
    const left = volume * sound.option.left;
    const right = volume * sound.option.right;

    var index: usize = 0;
    while (index < len) : (index += 2) {
        dstBuffer[index] += srcBuffer[index] * left;
        dstBuffer[index + 1] += srcBuffer[index + 1] * right;
    }
    sound.index += len;
    return len;
}

fn mixMonoSamples(dstBuffer: []f32, sound: *Sound, volume: f32) usize {
    const srcBuffer = sound.samples[sound.index..];
    const len = @min(dstBuffer.len / 2, srcBuffer.len);
    const left = volume * sound.option.left;
    const right = volume * sound.option.right;

    for (0..len) |index| {
        const src = srcBuffer[index];
        dstBuffer[index * 2] += src * left;
        dstBuffer[index * 2 + 1] += src * right;
    }
    sound.index += len;
    return len * 2;
}
