const input = @import("../input.zig");

pub const pad = @import("pad.zig");
pub const stick = @import("stick.zig");

// 两种控件共用功能按钮的配置和临时补丁。
pub const Option = pad.Option;
pub const patch = pad.patch;

// 选择方向按钮或摇杆，两种模式都产生统一按键。
pub const Mode = enum { pad, stick };
var mode: Mode = undefined; // 当前使用的控件，由 init 设置。
var enabled: bool = false; // 统一控制当前模式的输入和绘制。

// 初始化指定模式，根据输入环境决定是否启用控件。
pub fn init(value: Mode) void {
    enabled = input.key.mayNotHave;
    initMode(value);
}

// 初始化指定模式的布局和按钮配置，不修改统一启用状态。
fn initMode(value: Mode) void {
    mode = value;
    switch (value) {
        .pad => {
            // 切回按钮模式时显式显示四个方向，再刷新当前配置。
            for ([_]pad.Button{ .up, .left, .right, .down }) |button| {
                pad.defaults.getPtr(button).hidden = false;
            }
            pad.init();
        },
        .stick => stick.init(),
    }
}

// 运行时切换模式，释放旧按键并保留控件的启用状态。
pub fn use(value: Mode) void {
    if (mode == value) return;
    reset();
    initMode(value);
}

// 关闭控件时释放按键，重复设置不产生额外操作。
pub fn setEnabled(value: bool) void {
    if (enabled and !value) reset();
    enabled = value;
}

// 更新当前控件，暂存按键变化供下一帧读取。
pub fn update() void {
    if (!enabled) return;
    switch (mode) {
        .pad => pad.update(),
        .stick => stick.update(),
    }
}

// 绘制当前模式的方向控件和共用功能按钮。
pub fn draw() void {
    if (!enabled) return;
    switch (mode) {
        .pad => pad.draw(),
        .stick => stick.draw(),
    }
}

// 场景切换或停止更新前，释放当前控件产生的按键。
pub fn reset() void {
    switch (mode) {
        .pad => pad.reset(),
        .stick => stick.reset(),
    }
}
