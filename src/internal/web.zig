//! 浏览器宿主接口，JavaScript 源码直接嵌入 Emscripten 的链接段。

// 查询主要指针类型，用于推测是否缺少实体键盘。
pub extern "env" fn zhu_coarse_pointer() c_int;

extern fn zhu_fetch_done(c_int, c_int, c_int) void;

// 浏览器只登记完成结果，资源回调仍由下一帧执行。
export fn zhu_fetch_complete(lane: c_int, size: c_int, status: c_int) void {
    zhu_fetch_done(lane, size, status);
}

// 显式保留 JavaScript 读取 Wasm 字符串所需的运行库函数。
export var __em_lib_deps_zhu_storage align(1) linksection("em_lib_deps") =
    "$UTF8ToString".*;

// 创建离屏画布并保存唯一的字体状态。
export var __em_js__zhu_font_open align(1) linksection("em_js") =
    (
        \\(const char *family, unsigned int weight)<::>{
        \\    const canvas = typeof OffscreenCanvas !== "undefined"
        \\        ? new OffscreenCanvas(1, 1) : document.createElement("canvas");
        \\    const context = canvas.getContext("2d", { willReadFrequently: true });
        \\    if (!context) return 1;
        \\    // 字体系统只允许打开一个字体，直接保存供后续调用复用。
        \\    Module.zhu_font = {
        \\        canvas, context, family: UTF8ToString(family), weight,
        \\    };
        \\    return 0;
        \\}
    ).*;

// 释放浏览器保存的字体和离屏画布引用。
export var __em_js__zhu_font_close align(1) linksection("em_js") =
    (
        \\(void)<::>{
        \\    Module.zhu_font = null;
        \\}
    ).*;

// 设置像素字号并读取基线和行高度量。
export var __em_js__zhu_font_metrics align(1) linksection("em_js") =
    (
        \\(float size, float *out)<::>{
        \\    const zhuFont = Module.zhu_font;
        \\    zhuFont.style = zhuFont.weight + " " + size + "px " + zhuFont.family;
        \\    zhuFont.context.font = zhuFont.style;
        \\    const metrics = zhuFont.context.measureText("国Mg");
        \\    const ascent = metrics.fontBoundingBoxAscent
        \\        ?? metrics.actualBoundingBoxAscent;
        \\    const descent = metrics.fontBoundingBoxDescent
        \\        ?? metrics.actualBoundingBoxDescent;
        \\    HEAPF32[out >> 2] = ascent;
        \\    HEAPF32[(out >> 2) + 1] = descent;
        \\    HEAPF32[(out >> 2) + 2] = Math.max(size, ascent + descent);
        \\}
    ).*;

// 先读取字形边界，容量足够时才输出带透明边框的 RGBA。
export var __em_js__zhu_font_pixels align(1) linksection("em_js") =
    (
        \\(unsigned int code, float *info, unsigned char *out, unsigned int len)<::>{
        \\    const zhuFont = Module.zhu_font;
        \\    const context = zhuFont.context;
        \\    const text = String.fromCodePoint(code);
        \\    const metrics = context.measureText(text);
        \\    const left = Math.floor(-metrics.actualBoundingBoxLeft);
        \\    const top = Math.ceil(metrics.actualBoundingBoxAscent);
        \\    const width = Math.ceil(metrics.actualBoundingBoxRight) - left;
        \\    const height = top + Math.ceil(metrics.actualBoundingBoxDescent);
        \\    // Char 的内存顺序为 x、y、width、height、advance，基线上方的 y 为负。
        \\    HEAPF32[info >> 2] = left;
        \\    HEAPF32[(info >> 2) + 1] = -top;
        \\    HEAPF32[(info >> 2) + 2] = width;
        \\    HEAPF32[(info >> 2) + 3] = height;
        \\    HEAPF32[(info >> 2) + 4] = metrics.width;
        \\    if (width === 0 || height === 0) return 0;
        \\    // 包含一像素透明边框，Zig 可以将整块数据直接写入上传缓冲。
        \\    const copyWidth = width + 2;
        \\    const copyHeight = height + 2;
        \\    // 容量不足时不写入像素，等待调用方扩容后再次调用。
        \\    if (copyWidth * copyHeight * 4 > len) return 1;
        \\
        \\    // 修改画布尺寸会重置绘图状态，恢复 metrics 已设置的字体和字号。
        \\    zhuFont.canvas.width = copyWidth;
        \\    zhuFont.canvas.height = copyHeight;
        \\    context.font = zhuFont.style;
        \\    context.textBaseline = "alphabetic";
        \\    context.fillStyle = "white";
        \\    context.fillText(text, 1 - left, 1 + top);
        \\    const data = context.getImageData(0, 0, copyWidth, copyHeight).data;
        \\    HEAPU8.set(data, out);
        \\    return 0;
        \\}
    ).*;

// 通过媒体查询判断主要指针是否为粗略指针。
export var __em_js__zhu_coarse_pointer align(1) linksection("em_js") =
    (
        \\(void)<::>{
        \\    return window.matchMedia('(pointer: coarse)').matches ? 1 : 0;
        \\}
    ).*;

// 每个槽位只保留一个请求，完成后将结果通知 Wasm。
export var __em_js__zhu_fetch_start align(1) linksection("em_js") =
    (
        \\(int lane, const char *path, unsigned char *out, int len)<::>{
        \\    const jobs = Module.zhu_fetch_jobs ||= [];
        \\    const job = new AbortController();
        \\    jobs[lane] = job;
        \\    fetch("assets/" + UTF8ToString(path), { signal: job.signal })
        \\    .then(async response => {
        \\        if (!response.ok) {
        \\            if (jobs[lane] === job) {
        \\                jobs[lane] = null;
        \\                _zhu_fetch_complete(lane, 0, 1);
        \\            }
        \\            return;
        \\        }
        \\        const data = new Uint8Array(await response.arrayBuffer());
        \\        if (jobs[lane] !== job) return;
        \\        jobs[lane] = null;
        \\        if (data.length > len) {
        \\            _zhu_fetch_complete(lane, 0, 2);
        \\        } else {
        \\            HEAPU8.set(data, out);
        \\            _zhu_fetch_complete(lane, data.length, 0);
        \\        }
        \\    }).catch(() => {
        \\        if (jobs[lane] !== job) return;
        \\        jobs[lane] = null;
        \\        _zhu_fetch_complete(lane, 0, 3);
        \\    });
        \\}
    ).*;

// 中止全部请求，旧 Promise 不再访问已释放的缓冲区。
export var __em_js__zhu_fetch_stop align(1) linksection("em_js") =
    (
        \\(void)<::>{
        \\    const jobs = Module.zhu_fetch_jobs || [];
        \\    for (let lane = 0; lane < jobs.length; lane++) {
        \\        const job = jobs[lane];
        \\        jobs[lane] = null;
        \\        if (job) job.abort();
        \\    }
        \\}
    ).*;

// 检查浏览器中是否存在存档。
export var __em_js__zhu_file_exists align(1) linksection("em_js") =
    (
        \\(const char *name)<::>{
        \\    const path = UTF8ToString(name);
        \\    try {
        \\        return window.localStorage.getItem(path) !== null;
        \\    } catch (err) {
        \\        console.error("check file failed:", path, err);
        \\        return false;
        \\    }
        \\}
    ).*;

// 读取存档字节，缓冲区不足时返回所需长度的负值。
export var __em_js__zhu_file_load align(1) linksection("em_js") =
    (
        \\(const char *name, unsigned char *out, int len)<::>{
        \\    const path = UTF8ToString(name);
        \\    try {
        \\        const base64 = window.localStorage.getItem(path);
        \\        if (!base64) return 0;
        \\        const binary = atob(base64);
        \\        if (binary.length > len) return -binary.length;
        \\        for (let i = 0; i < binary.length; i++) {
        \\            HEAPU8[out + i] = binary.charCodeAt(i);
        \\        }
        \\        return binary.length;
        \\    } catch (err) {
        \\        console.error("load file failed:", path, err);
        \\        return 0;
        \\    }
        \\}
    ).*;

// 将存档字节编码为 Base64，保存到浏览器。
export var __em_js__zhu_file_save align(1) linksection("em_js") =
    (
        \\(const char *name, const unsigned char *data, int len)<::>{
        \\    const path = UTF8ToString(name);
        \\    let text = "";
        \\    for (let pos = data; pos < data + len; pos += 0x8000) {
        \\        const end = Math.min(pos + 0x8000, data + len);
        \\        const chars = new Array(end - pos);
        \\        for (let i = pos; i < end; i++) {
        \\            chars[i - pos] = String.fromCharCode(HEAPU8[i]);
        \\        }
        \\        text += chars.join("");
        \\    }
        \\    try {
        \\        window.localStorage.setItem(path, btoa(text));
        \\        return 0;
        \\    } catch (err) {
        \\        console.error("save file failed:", path, err);
        \\        return 1;
        \\    }
        \\}
    ).*;
