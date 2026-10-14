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
    pub const Audio = opaque {
        pub fn getInfo(self: *Audio) AudioInfo {
            return stb_vorbis_get_info(self);
        }

        pub fn getSampleCount(self: *Audio) usize {
            return stb_vorbis_stream_length_in_samples(self);
        }

        // 完整 PCM 所需的 f32 元素数，包含全部原始声道。
        pub fn getSampleCapacity(self: *Audio) usize {
            const channels: usize = @intCast(self.getInfo().channels);
            return self.getSampleCount() * channels;
        }

        // 按原始声道写入 PCM，返回每声道采样数。
        pub fn fillSamples(self: *Audio, buffer: []f32) i32 {
            return stb_vorbis_get_samples_float_interleaved(
                self,
                self.getInfo().channels,
                buffer.ptr,
                @intCast(buffer.len),
            );
        }

        // 请求双声道输出，缺失的声道由 Vorbis 补零。
        pub fn fillStereoSamples(self: *Audio, buffer: []f32) i32 {
            return stb_vorbis_get_samples_float_interleaved(
                self,
                2,
                buffer.ptr,
                @intCast(buffer.len),
            );
        }

        pub fn reset(self: *Audio) void {
            _ = stb_vorbis_seek_start(self);
        }

        pub fn unload(self: *Audio) void {
            stb_vorbis_close(self);
        }
    };

    // 按值返回，字段类型和顺序必须与 stb_vorbis_info 完整对应。
    pub const AudioInfo = extern struct {
        sample_rate: c_uint,
        channels: c_int,
        setup_memory_required: c_uint,
        setup_temp_memory_required: c_uint,
        temp_memory_required: c_uint,
        max_frame_size: c_int,
    };

    const Alloc = extern struct {
        alloc_buffer: ?[*]u8,
        alloc_buffer_length_in_bytes: c_int,
    };

    extern fn stb_vorbis_open_memory(
        data: [*]const u8,
        len: c_int,
        error_code: ?*c_int,
        alloc_buffer: ?*const Alloc,
    ) ?*Audio;
    extern fn stb_vorbis_get_info(audio: *Audio) AudioInfo;
    extern fn stb_vorbis_stream_length_in_samples(audio: *Audio) c_uint;
    extern fn stb_vorbis_get_samples_float_interleaved(
        audio: *Audio,
        channels: c_int,
        buffer: [*]f32,
        num_floats: c_int,
    ) c_int;
    extern fn stb_vorbis_seek_start(audio: *Audio) c_int;
    extern fn stb_vorbis_close(audio: *Audio) void;

    pub fn loadFromMemory(data: []const u8) *Audio {
        var errorCode: c_int = 0;

        const vorbis = stb_vorbis_open_memory(
            data.ptr,
            @intCast(data.len),
            &errorCode,
            null,
        );
        return vorbis.?;
    }
};

pub const em = struct {
    const api = @import("std").os.emscripten;

    pub const Load = union(enum) {
        loaded: []u8,
        tooSmall: usize,
    };

    /// 检查浏览器中是否存在存档。
    pub fn exists(path: [:0]const u8) bool {
        var scriptBuffer: [1024]u8 = undefined;
        const script = memory.formatZ(&scriptBuffer,
            \\(() => {{
            \\    const path = UTF8ToString({d});
            \\    try {{
            \\        return localStorage.getItem(path) !== null;
            \\    }} catch (err) {{
            \\        console.error("check file failed:", path, err);
            \\        return false;
            \\    }}
            \\}})()
        , .{@intFromPtr(path.ptr)});
        return api.emscripten_run_script_int(script.ptr) != 0;
    }

    /// 读取浏览器存档，将原始字节写入传入的缓冲区。
    pub fn load(path: [:0]const u8, buffer: []u8) !Load {
        var scriptBuffer: [2048]u8 = undefined;
        const script = memory.formatZ(&scriptBuffer,
            \\(() => {{
            \\    const path = UTF8ToString({d});
            \\    const out = {d};
            \\    const len = {d};
            \\    try {{
            \\        const base64 = localStorage.getItem(path);
            \\        if (!base64) return 0;
            \\        const binary = atob(base64);
            \\        if (binary.length > len) return -binary.length;
            \\        for (let i = 0; i < binary.length; i++) {{
            \\            HEAPU8[out + i] = binary.charCodeAt(i);
            \\        }}
            \\        return binary.length;
            \\    }} catch (err) {{
            \\        console.error("load file failed:", path, err);
            \\        return 0;
            \\    }}
            \\}})()
        , .{ @intFromPtr(path.ptr), @intFromPtr(buffer.ptr), buffer.len });
        const len = api.emscripten_run_script_int(script.ptr);
        if (len == 0) return error.FileNotFound;
        if (len < 0) return .{ .tooSmall = @intCast(-len) };
        return .{ .loaded = buffer[0..@intCast(len)] };
    }

    /// 将存档字节编码为 Base64，保存到浏览器。
    pub fn save(path: [:0]const u8, data: []const u8) !void {
        var scriptBuffer: [2048]u8 = undefined;
        const script = memory.formatZ(&scriptBuffer,
            \\(() => {{
            \\    const path = UTF8ToString({d});
            \\    const data = {d};
            \\    const len = {d};
            \\    let text = "";
            \\    for (let pos = data; pos < data + len; pos += 0x8000) {{
            \\        const end = Math.min(pos + 0x8000, data + len);
            \\        const chars = new Array(end - pos);
            \\        for (let i = pos; i < end; i++) {{
            \\            chars[i - pos] = String.fromCharCode(HEAPU8[i]);
            \\        }}
            \\        text += chars.join("");
            \\    }}
            \\    try {{
            \\        localStorage.setItem(path, btoa(text));
            \\        return 0;
            \\    }} catch (err) {{
            \\        console.error("save file failed:", path, err);
            \\        return 1;
            \\    }}
            \\}})()
        , .{ @intFromPtr(path.ptr), @intFromPtr(data.ptr), data.len });
        const err = api.emscripten_run_script_int(script.ptr);
        if (err != 0) return error.WriteFailed;
    }
};
