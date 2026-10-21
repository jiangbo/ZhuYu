pub const em = struct {
    pub const Load = union(enum) {
        loaded: []u8,
        tooSmall: usize,
    };

    // 浏览器存档函数由 web.c 中的 EM_JS 静态接入。
    extern fn zhu_file_keep() void;
    extern fn zhu_file_exists(path: [*:0]const u8) c_int;
    extern fn zhu_file_load(path: [*:0]const u8, out: [*]u8, len: c_int) c_int;
    extern fn zhu_file_save(path: [*:0]const u8, data: [*]const u8, len: c_int) c_int;

    /// 检查浏览器中是否存在存档。
    pub fn exists(path: [:0]const u8) bool {
        zhu_file_keep();
        return zhu_file_exists(path.ptr) != 0;
    }

    /// 读取浏览器存档，将原始字节写入传入的缓冲区。
    pub fn load(path: [:0]const u8, buffer: []u8) !Load {
        zhu_file_keep();
        const len = zhu_file_load(path.ptr, buffer.ptr, @intCast(buffer.len));
        if (len == 0) return error.FileNotFound;
        if (len < 0) return .{ .tooSmall = @intCast(-len) };
        return .{ .loaded = buffer[0..@intCast(len)] };
    }

    /// 将存档字节编码为 Base64，保存到浏览器。
    pub fn save(path: [:0]const u8, data: []const u8) !void {
        zhu_file_keep();
        const err = zhu_file_save(path.ptr, data.ptr, @intCast(data.len));
        if (err != 0) return error.WriteFailed;
    }
};
