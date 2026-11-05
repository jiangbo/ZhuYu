const std = @import("std");
const zhu = @import("zhu");

var commands: [8]zhu.batch.Command = undefined; // 示例持有绘制命令缓冲。

// 窗口创建后初始化绘制，不加载外部资源。
pub fn init(_: zhu.Allocator) void {
    zhu.batch.init(&commands);
}

// 每帧清屏并提交绘制。
pub fn frame(_: f32) void {
    zhu.batch.beginDraw(.rgba(32, 64, 96, 255), .{});
    zhu.batch.endDraw();
}

// 初始化引擎并创建窗口，平台回调由引擎管理。
pub fn main(info: std.process.Init) void {
    zhu.init(info);
    zhu.window.run("ZhuYu clear", .xy(640, 480), .{});
}
