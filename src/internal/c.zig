const memory = @import("memory.zig");

export fn c_alloc(len: usize) ?*anyopaque {
    return memory.alloc(len);
}

export fn c_realloc(ptr: ?*anyopaque, len: usize) ?*anyopaque {
    return memory.realloc(ptr, len);
}

export fn c_free(ptr: ?*anyopaque) void {
    memory.free(ptr);
}

pub const stbAudio = stbVorbis;
pub const stbVorbis = struct {
    const stb = @cImport({
        @cDefine("STB_VORBIS_NO_PUSHDATA_API", {});
        @cDefine("STB_VORBIS_HEADER_ONLY", {});
        @cDefine("STB_VORBIS_NO_INTEGER_CONVERSION", {});
        @cDefine("STB_VORBIS_NO_STDIO", {});
        @cInclude("stb_vorbis.c");
    });

    pub const Audio = stb.stb_vorbis;
    pub const AudioInfo = stb.stb_vorbis_info;

    pub fn loadFromMemory(data: []const u8) *Audio {
        var errorCode: c_int = 0;

        const vorbis = stb.stb_vorbis_open_memory(
            data.ptr,
            @intCast(data.len),
            &errorCode,
            null,
        );
        return vorbis.?;
    }

    pub fn getInfo(audio: *Audio) AudioInfo {
        return stb.stb_vorbis_get_info(audio);
    }

    pub fn getSampleCount(audio: *Audio) i32 {
        return @intCast(stb.stb_vorbis_stream_length_in_samples(audio));
    }

    pub fn fillSamples(audio: *Audio, buffer: []f32, channels: i32) c_int {
        return stb.stb_vorbis_get_samples_float_interleaved(
            audio,
            channels,
            @ptrCast(buffer),
            @intCast(buffer.len),
        );
    }

    pub fn reset(audio: *Audio) void {
        _ = stb.stb_vorbis_seek_start(audio);
    }

    pub fn unload(audio: *Audio) void {
        stb.stb_vorbis_close(audio);
    }
};

pub const em = struct {
    pub const Load = union(enum) {
        loaded: []u8,
        tooSmall: usize,
    };

    extern fn em_js_keep() void;
    extern fn em_js_file_save(path: [*]const u8, data: [*]const u8, len: c_int) c_int;
    extern fn em_js_file_load(c_path: [*]const u8, out_buf: [*]u8, buf_size: c_int) c_int;

    pub fn load(path: [:0]const u8, buffer: []u8) !Load {
        em_js_keep();
        const len = em_js_file_load(path.ptr, buffer.ptr, @intCast(buffer.len));
        if (len == 0) return error.FileNotFound;
        if (len < 0) return .{ .tooSmall = @intCast(-len) };
        return .{ .loaded = buffer[0..@intCast(len)] };
    }

    pub fn save(path: [:0]const u8, data: []const u8) !void {
        em_js_keep();
        const err = em_js_file_save(path.ptr, data.ptr, @intCast(data.len));
        if (err != 0) return error.WriteFailed;
    }
};
