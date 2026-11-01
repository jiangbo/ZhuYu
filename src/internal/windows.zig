//! Windows 平台接口。
const std = @import("std");

// 使用 Zig 自带的导入库名称，Linux 交叉编译时也能找到。
pub extern "imm32" fn ImmDisableIME(i32) std.os.windows.BOOL;
