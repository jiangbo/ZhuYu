const std = @import("std");
const sk = @import("sokol");
const assets = @import("assets.zig");
const memory = @import("internal/memory.zig");
const stbAudio = @import("internal/c.zig").stbAudio;

var mutex: std.Io.Mutex = .init;
pub var paused: std.atomic.Value(bool) = .init(false);

/// 使用 Sokol 配置初始化音频，num_channels 为 0 时使用双声道。
/// 未提供回调、日志或分配器时使用引擎默认值；自定义回调接管音频输出。
pub fn init(soundBuffer: []Sound, option: sk.audio.Desc) void {
    var desc = option;
    if (desc.num_channels == 0) desc.num_channels = 2;
    std.debug.assert(desc.num_channels == 1 or desc.num_channels == 2);
    sounds = soundBuffer;
    for (sounds) |*sound| sound.state = .stopped;

    if (desc.stream_cb == null and desc.stream_userdata_cb == null) {
        desc.stream_cb = audioCallback;
    }
    if (desc.logger.func == null) desc.logger.func = sk.log.func;
    if (desc.allocator.alloc_fn == null and desc.allocator.free_fn == null) {
        desc.allocator = memory.sokolAllocator(sk.audio.Allocator);
    }

    // 启动音频线程
    sk.audio.setup(desc);
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

    source.?.reset();
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
        const count = source.fillSamples(buffer[len..], channels);
        len += @as(usize, @intCast(count * channels));

        if (len == buffer.len) break;
        if (music.loop) source.reset() else music.state = .stopped;
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

// 按帧应用左右音量，单声道输出取左右平均值。
fn mixSamples(buffer: []f32, sound: *Sound, volume: f32) usize {
    const channels: usize = @intCast(sk.audio.channels());
    const source = sound.samples[sound.index..];
    const frames = @min(buffer.len / channels, source.len / sound.channels);
    const left = volume * sound.option.left;
    const right = volume * sound.option.right;

    for (0..frames) |frame| {
        const index = frame * sound.channels;
        const l = source[index] * left;
        const r = source[index + sound.channels - 1] * right;
        if (channels == 1) {
            buffer[frame] += (l + r) * 0.5;
        } else {
            buffer[frame * 2] += l;
            buffer[frame * 2 + 1] += r;
        }
    }
    sound.index += frames * sound.channels;
    if (sound.index == sound.samples.len) {
        if (sound.option.loop) sound.index = 0 else sound.state = .stopped;
    }
    return frames * channels;
}
