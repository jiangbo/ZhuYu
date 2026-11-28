const std = @import("std");
const sk = @import("sokol");

const assets = @import("assets.zig");
const vorbis = @import("internal/vorbis.zig");

const Allocator = std.mem.Allocator;

var mutex: std.Io.Mutex = .init;
pub var paused: std.atomic.Value(bool) = .init(false);

pub const InitOption = struct {
    sampleRate: i32 = 0, // 0 使用后端默认采样率。
    channels: i32 = 2,
    bufferFrames: i32 = 0, // 0 使用后端默认缓冲大小。
    // 自定义回调接管音频输出。
    streamCallback: ?*const fn ([*c]f32, i32, i32) callconv(.c) void = null,
    // 音频运行期间保持列表和后缀有效且不可修改。
    decoders: []const MusicDecoder = &.{},
};

pub fn init(soundBuffer: []Sound, comptime option: InitOption) void {
    std.debug.assert(option.channels == 1 or option.channels == 2);
    sounds = soundBuffer;
    for (sounds) |*sound| sound.* = .{};

    sk.audio.setup(.{
        .sample_rate = option.sampleRate,
        .num_channels = option.channels,
        .buffer_frames = option.bufferFrames,
        .stream_cb = option.streamCallback orelse audioCallback,
        .logger = .{ .func = sk.log.func },
        .allocator = assets.sokolAllocator(sk.audio.Allocator),
    });
    if (sk.audio.isvalid()) musicDecoders = option.decoders;
}

pub fn deinit() void {
    if (!sk.audio.isvalid()) return;
    stopMusic(0);
    stopSounds();
    sk.audio.shutdown();
    musicDecoders = &.{};
}

pub fn setVolume(volume: f32) void {
    setMusicVolume(volume);
    setSoundVolume(volume);
}

pub fn changeVolume(amount: f32) void {
    changeMusicVolume(amount);
    changeSoundVolume(amount);
}

pub fn getMusicVolume() f32 {
    return musicVolume.load(.acquire);
}

pub fn setMusicVolume(volume: f32) void {
    musicVolume.store(std.math.clamp(volume, 0, 1), .release);
}

pub fn changeMusicVolume(amount: f32) void {
    setMusicVolume(getMusicVolume() + amount);
}

pub fn getSoundVolume() f32 {
    return soundVolume.load(.acquire);
}

pub fn setSoundVolume(volume: f32) void {
    soundVolume.store(std.math.clamp(volume, 0, 1), .release);
}

pub fn changeSoundVolume(amount: f32) void {
    setSoundVolume(getSoundVolume() + amount);
}

pub var musicVolume: std.atomic.Value(f32) = .init(1);
var music: struct {
    pending: ?MusicRequest = null, // 等待音源或切换时机的最新请求。
    current: ?Music = null, // 当前曲目，停止后仍保留。
    fading: ?Music = null, // 交叉淡化期间仍在播放的旧曲。
    stopping: ?Fade = null, // 停止时，对新旧曲混合后的输出一起淡出。
    paused: bool = false, // 冻结两首曲目的播放位置和淡化进度。
} = .{};

pub const MusicState = enum { pending, playing, paused, stopped };

pub const MusicDecoder = struct {
    extensions: []const []const u8,
    // 文件字节仅在 open 调用期间借用。
    open: *const fn (Allocator, []const u8, u32) anyerror!MusicSource.Custom,
};

var musicDecoders: []const MusicDecoder = &.{};

pub const MusicSource = union(enum) {
    vorbis: *vorbis.Player,
    custom: Custom,

    pub const Custom = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // 生成交错 PCM，返回帧数。缓冲区未写满表示曲目结束。
            fillSamples: *const fn (*anyopaque, []f32, i32) i32,
            // 复位后，非空缓冲区必须能读到至少一帧。
            reset: *const fn (*anyopaque) void,
            deinit: *const fn (*anyopaque, Allocator) void,
        };
    };

    /// Vorbis 资源采样率需与实际输出一致。
    pub fn init(
        gpa: Allocator,
        path: []const u8,
        data: []const u8,
        rate: u32,
    ) !MusicSource {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".ogg")) {
            const player = try gpa.create(vorbis.Player);
            errdefer gpa.destroy(player);
            try player.init(gpa, data);
            // 音乐必须包含可播放的帧。
            std.debug.assert(player.sampleCount > 0);
            return .{ .vorbis = player };
        }

        for (musicDecoders) |decoder| {
            for (decoder.extensions) |extension| {
                if (!std.ascii.eqlIgnoreCase(ext, extension)) continue;
                return .{ .custom = try decoder.open(gpa, data, rate) };
            }
        }
        return error.UnsupportedMusicFormat;
    }

    /// 释放播放器及其持有的数据；使用创建时的同一个分配器。
    pub fn deinit(self: MusicSource, gpa: Allocator) void {
        switch (self) {
            .vorbis => |player| {
                player.deinit();
                gpa.destroy(player);
            },
            .custom => |source| source.vtable.deinit(source.ptr, gpa),
        }
    }

    /// 将当前格式的解码器复位到音乐开头。
    pub fn reset(self: MusicSource) void {
        switch (self) {
            .vorbis => |player| player.reset(),
            .custom => |source| source.vtable.reset(source.ptr),
        }
    }

    /// 生成交错 PCM，返回实际填充的帧数。
    pub fn fillSamples(self: MusicSource, buffer: []f32, channels: i32) i32 {
        return switch (self) {
            .vorbis => |player| player.fillSamples(buffer, channels),
            .custom => |src| src.vtable.fillSamples(src.ptr, buffer, channels),
        };
    }
};

const Music = struct {
    source: MusicSource,
    assetId: assets.Id,
    playing: bool = true,
    loop: bool = true,
    fade: ?Fade = null,
};

// 请求只保存时长（帧数），开始淡化时才创建可递减的进度。
const MusicRequest = struct {
    source: ?MusicSource,
    assetId: assets.Id,
    loop: bool,
    fadeIn: u64,
    fadeOut: u64,
    immediate: bool,
};

// 总帧数用于计算增益，剩余帧数随混音推进。
const Fade = struct { frames: u64, remaining: u64 };
pub const MusicOption = struct {
    loop: bool = true,
    fadeIn: f32 = 0, // 新曲淡入时长，单位为秒。
    fadeOut: f32 = 0, // 切歌时旧曲的淡出时长，单位为秒。
    immediate: bool = false, // 新曲就绪即接管，跳过旧曲淡出。
};

/// 新曲就绪后切换，重播正在播放的同曲时直接从头播放。
pub fn playMusic(path: []const u8, option: MusicOption) void {
    if (!sk.audio.isvalid()) return;
    const fadeIn = fadeFrames(option.fadeIn);
    const fadeOut = if (option.immediate) 0 else fadeFrames(option.fadeOut);

    const assetId = assets.id(path);
    const source = assets.music.load(path, musicLoaded);

    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);

    if (music.paused and !option.immediate) finishMusic();
    music.pending = .{
        .source = source,
        .assetId = assetId,
        .loop = option.loop,
        .fadeIn = fadeIn,
        .fadeOut = fadeOut,
        .immediate = option.immediate,
    };
    if (option.immediate) startPendingMusic();
}

fn musicLoaded(assetId: assets.Id, source: MusicSource) void {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    if (music.pending) |*request| {
        if (request.assetId != assetId) return;
        request.source = source;
        if (request.immediate) startPendingMusic();
    }
}

fn startPendingMusic() void {
    const request = music.pending orelse return;
    const source = request.source orelse return;
    if (request.immediate) {
        finishMusic();
    } else if (music.stopping != null) return;

    const current = music.current;
    const id = request.assetId;
    // 播放中的同曲共用一个解码器，直接复位重播。
    const same = if (current) |track| track.playing and track.assetId == id else false;
    const fade = !same and (request.fadeIn != 0 or request.fadeOut != 0);
    const entering = if (current) |track| track.fade != null else false;
    // 上一次淡入或淡出仍在进行时，新的渐变请求继续等待。
    if (fade and (entering or music.fading != null)) return;

    music.fading = null;
    if (current) |track| {
        if (fade and request.fadeOut != 0 and track.playing) {
            music.fading = track;
            music.fading.?.fade = newFade(request.fadeOut);
        }
    }
    source.reset();
    music.current = .{
        .source = source,
        .assetId = id,
        .loop = request.loop,
        .fade = if (fade and request.fadeIn != 0) newFade(request.fadeIn) else null,
    };
    music.pending = null;
}

pub fn pauseMusic() void {
    setMusicPaused(true);
}

pub fn resumeMusic() void {
    setMusicPaused(false);
}

fn setMusicPaused(value: bool) void {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    const state = musicState();
    music.paused = value and state != null and state != .stopped;
}

/// 取消待播请求，淡化时长以秒为单位。
pub fn stopMusic(fade: f32) void {
    const frames = if (fade == 0) 0 else fadeFrames(fade);
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    music.pending = null;
    if (frames != 0 and musicState() == .playing) {
        if (music.stopping == null) music.stopping = newFade(frames);
    } else finishMusic();
}

/// 返回整个音乐播放流程的状态快照。
pub fn getMusicState() ?MusicState {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    return musicState();
}

fn musicState() ?MusicState {
    if (music.paused) return .paused;
    if (music.current) |track| {
        if (track.playing or music.fading != null or music.stopping != null) {
            return .playing;
        }
    }
    if (music.pending != null) return .pending;
    return if (music.current != null) .stopped else null;
}

fn finishMusic() void {
    if (music.current) |*track| {
        track.playing = false;
        track.fade = null;
    }
    music.fading = null;
    music.stopping = null;
    music.paused = false;
}

fn fadeFrames(seconds: f32) u64 {
    std.debug.assert(seconds >= 0 and std.math.isFinite(seconds));
    const rate: f64 = @floatFromInt(sk.audio.sampleRate());
    return @intFromFloat(@round(rate * seconds));
}

fn newFade(frames: u64) Fade {
    return .{ .frames = frames, .remaining = frames };
}

pub const Sound = struct {
    pub const Option = struct {
        loop: bool = false,
        left: f32 = 1,
        right: f32 = 1,
    };
    source: ?SoundSource = null,
    option: Option = .{},
    assetId: ?assets.Id = null,

    index: usize = 0,
};

pub const SoundSource = vorbis.Sound;

pub var soundVolume: std.atomic.Value(f32) = .init(1);
var sounds: []Sound = &.{};

pub fn playSound(path: []const u8) void {
    _ = playSoundOption(path, .{});
}

pub fn playSoundOption(path: []const u8, option: Sound.Option) ?usize {
    if (!sk.audio.isvalid()) return null;

    var opt = option;
    opt.left = std.math.clamp(opt.left, 0.0, 1.0);
    opt.right = std.math.clamp(opt.right, 0.0, 1.0);
    const id = assets.id(path);
    const source = assets.sound.load(path, soundLoaded);
    mutex.lockUncancelable(assets.io);
    const index = allocSoundIndex();
    sounds[index] = .{ .assetId = id, .source = source, .option = opt };
    mutex.unlock(assets.io);

    return index;
}

/// 资产层在主线程通知就绪，启动等待同一资源的全部音效。
fn soundLoaded(assetId: assets.Id, source: SoundSource) void {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    for (sounds) |*sound| {
        if (sound.source == null and sound.assetId == assetId) {
            sound.source = source;
        }
    }
}

pub fn stopSounds() void {
    mutex.lockUncancelable(assets.io);
    defer mutex.unlock(assets.io);
    for (sounds) |*sound| sound.* = .{};
}

fn allocSoundIndex() usize {
    for (sounds, 0..) |*sound, index| {
        if (sound.assetId == null) return index;
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

    fillMusic(buffer, @intCast(channels));
    fillSound(buffer);
}

fn fillMusic(buffer: []f32, channels: usize) void {
    if (music.paused) return;
    if (music.stopping) |*fade| {
        const frames: usize = @intCast(@min(fade.remaining, buffer.len / channels));
        const len = frames * channels;
        mixMusic(buffer[0..len], channels);
        for (0..frames) |frame| {
            const gain = fadeGain(fade.*, frame);
            const offset = frame * channels;
            for (buffer[offset..][0..channels]) |*sample| sample.* *= gain;
        }
        fade.remaining -= frames;
        if (fade.remaining == 0) finishMusic();
        // 淡出完成后，可用缓冲区剩余帧播放新曲。
        if (len < buffer.len) mixMusic(buffer[len..], channels);
        return;
    }
    mixMusic(buffer, channels);
}

fn fadeGain(fade: Fade, frame: usize) f32 {
    const total: f32 = @floatFromInt(fade.frames);
    const remaining: f32 = @floatFromInt(fade.remaining - frame);
    return remaining / total;
}

fn mixMusic(buffer: []f32, channels: usize) void {
    const volume = musicVolume.load(.acquire);
    var scratch: [512]f32 = undefined;
    var rest = buffer;
    while (rest.len != 0) {
        startPendingMusic();
        const track = if (music.current) |*value| value else return;
        const previous = if (music.fading) |*old| old else null;
        const incoming = if (track.fade) |fade| fade.remaining else 0;
        const outgoing = if (previous) |old| old.fade.?.remaining else 0;
        const transition = @max(incoming, outgoing);
        if (transition == 0) {
            const len = readMusic(track, rest, channels);
            for (rest[0..len]) |*sample| sample.* *= volume;
            return;
        }

        const limit = @min(rest.len, scratch.len) / channels;
        const frames: usize = @intCast(@min(transition, limit));
        const len = frames * channels;
        const next = rest[0..len];
        _ = readMusic(track, next, channels);
        applyTrackFade(track, next, channels, false);

        if (previous) |old| {
            const oldFrames: usize = @intCast(@min(outgoing, frames));
            const tail = scratch[0 .. oldFrames * channels];
            @memset(tail, 0);
            _ = readMusic(old, tail, channels);
            applyTrackFade(old, tail, channels, true);
            for (next[0..tail.len], tail) |*sample, fading| sample.* += fading;
            if (old.fade == null) music.fading = null;
        }
        for (next) |*sample| sample.* *= volume;
        rest = rest[len..];
    }
}

fn applyTrackFade(track: *Music, buffer: []f32, channels: usize, out: bool) void {
    const fade = if (track.fade) |*value| value else return;
    const frames: usize = @intCast(@min(fade.remaining, buffer.len / channels));
    for (0..frames) |frame| {
        const remaining = fadeGain(fade.*, frame);
        const gain = if (out) remaining else 1 - remaining;
        const offset = frame * channels;
        for (buffer[offset..][0..channels]) |*sample| sample.* *= gain;
    }
    fade.remaining -= frames;
    if (fade.remaining == 0 or !track.playing) track.fade = null;
}

fn readMusic(track: *Music, buffer: []f32, channels: usize) usize {
    const source = track.source;
    const countChannels: i32 = @intCast(channels);
    var len: usize = 0;
    var afterReset = false;
    while (track.playing) {
        const frames = source.fillSamples(buffer[len..], countChannels);
        std.debug.assert(!afterReset or frames != 0);
        len += @as(usize, @intCast(frames)) * channels;
        if (len == buffer.len) break;
        if (track.loop) {
            source.reset();
            afterReset = true;
        } else track.playing = false;
    }
    return len;
}

fn fillSound(buffer: []f32) void {
    const volume = soundVolume.load(.acquire);

    // 填充声音
    for (sounds) |*sound| {
        var len: usize = 0;
        if (sound.source == null) continue;
        while (len < buffer.len and sound.source != null) {
            len += mixSamples(buffer[len..], sound, volume);
        }
    }
}

// 按帧应用左右音量，单声道输出取左右平均值。
fn mixSamples(buffer: []f32, sound: *Sound, volume: f32) usize {
    const channels: usize = @intCast(sk.audio.channels());
    const source = sound.source.?;
    const samples = source.samples[sound.index..];
    const frames = @min(buffer.len / channels, samples.len / source.channels);
    const left = volume * sound.option.left;
    const right = volume * sound.option.right;

    for (0..frames) |frame| {
        const index = frame * source.channels;
        const l = samples[index] * left;
        const r = samples[index + source.channels - 1] * right;
        if (channels == 1) {
            buffer[frame] += (l + r) * 0.5;
        } else {
            buffer[frame * 2] += l;
            buffer[frame * 2 + 1] += r;
        }
    }
    sound.index += frames * source.channels;
    if (sound.index == source.samples.len) {
        if (sound.option.loop) sound.index = 0 else sound.* = .{};
    }
    return frames * channels;
}
