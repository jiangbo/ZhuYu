//! 平台实现选择与共用的适配逻辑。
const builtin = @import("builtin");
const sk = @import("sokol");

pub const backend = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .macos, .ios => @import("apple.zig"),
    .linux => if (builtin.abi.isAndroid())
        @import("android.zig")
    else
        @import("linux.zig"),
    .emscripten => @import("web.zig"),
    else => struct {},
};

pub fn run(desc: sk.app.Desc, disableIME: bool) void {
    if (builtin.os.tag == .windows and disableIME) {
        _ = backend.ImmDisableIME(-1);
    }
    if (!builtin.abi.isAndroid()) return sk.app.run(desc);
    backend.desc = desc;
}

// 浏览器查询主要指针类型，移动平台默认推测没有实体键盘。
pub fn mayNotHaveKeyboard() bool {
    if (builtin.os.tag == .emscripten) return backend.zhu_coarse_pointer() != 0;
    return builtin.abi.isAndroid() or builtin.os.tag == .ios;
}
