const std = @import("std");
const sk = @import("sokol");
const shader = @import("shader");
const batch = @import("../batch.zig");
const text = @import("../text.zig");

var pipeline: sk.gfx.Pipeline = undefined;
var buffer: [8]sk.gfx.Pipeline = undefined;
pub var stack: std.ArrayList(sk.gfx.Pipeline) = .initBuffer(&buffer);

// 初始化 MSDF 字体和渲染资源。
pub fn init(zon: text.static.Font) void {
    text.static.init(zon, .linear);
    const desc = shader.msdfShaderDesc(sk.gfx.queryBackend());
    pipeline = batch.createPipeline(desc);
    stack.clearRetainingCapacity();
}

// 切换后续文字使用 MSDF 渲染状态。
pub fn begin() void {
    stack.appendAssumeCapacity(batch.queryPipeline());
    batch.usePipeline(pipeline);
}

// 恢复进入 MSDF 前使用的流水线。
pub fn end() void {
    batch.usePipeline(stack.pop().?);
}
