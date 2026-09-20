const std = @import("std");
const app = @import("app");

// Zig 0.16's default Emscripten entry point and panic handler pull in
// std.Io.Threaded, which does not compile for wasm32-emscripten. Web builds do
// not use the process IO backend: ZhuYu loads browser assets through em.js.
pub const panic = std.debug.no_panic;
pub const std_options_debug_io = std.Io.failing;

pub fn main() void {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    app.main(.{
        .minimal = .{
            .args = .{ .vector = &.{} },
            .environ = .empty,
        },
        .arena = &arena,
        .gpa = gpa,
        .io = std.Io.failing,
        .environ_map = &environ_map,
        .preopens = .empty,
    });
}

fn call(comptime name: []const u8, args: anytype) void {
    if (@hasDecl(app, name)) @call(.auto, @field(app, name), args);
}

pub fn init(allocator: anytype) void {
    call("init", .{allocator});
}

pub fn event(value: anytype) void {
    call("event", .{value});
}

pub fn frame(delta: f32) void {
    call("frame", .{delta});
}

pub fn deinit(allocator: anytype) void {
    call("deinit", .{allocator});
}
