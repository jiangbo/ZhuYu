#include <emscripten.h>

// 存档函数需要将 Wasm 中的路径转换为 JavaScript 字符串。
EM_JS_DEPS(zhu_storage, "$UTF8ToString");

// 让静态库链接器带入本文件中的 JavaScript 函数描述。
void zhu_web_keep(void) {}

// 仅 Web 的必要宿主胶水：复用离屏画布，输出 RGBA 像素到 WASM 内存。
// 初始化成功返回 0，无法获取绘图上下文时返回 1。
EM_JS(int, zhu_font_open, (const char *family, unsigned int weight), {
    const canvas = typeof OffscreenCanvas !== "undefined"
        ? new OffscreenCanvas(1, 1) : document.createElement("canvas");
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) return 1;
    // 字体系统只允许打开一个字体，直接保存供后续调用复用。
    Module.zhu_font = { canvas, context, family: UTF8ToString(family), weight };
    return 0;
});

EM_JS(void, zhu_font_close, (void), {
    Module.zhu_font = null;
});

// 设置当前像素字号并返回字体度量，后续字形生成复用此设置。
EM_JS(void, zhu_font_metrics, (float size, float *out), {
    const zhuFont = Module.zhu_font;
    zhuFont.style = zhuFont.weight + " " + size + "px " + zhuFont.family;
    zhuFont.context.font = zhuFont.style;
    const metrics = zhuFont.context.measureText("国Mg");
    const ascent = metrics.fontBoundingBoxAscent ?? metrics.actualBoundingBoxAscent;
    const descent = metrics.fontBoundingBoxDescent ?? metrics.actualBoundingBoxDescent;
    HEAPF32[out >> 2] = ascent;
    HEAPF32[(out >> 2) + 1] = descent;
    HEAPF32[(out >> 2) + 2] = Math.max(size, ascent + descent);
});

// 一次返回字形信息和 RGBA 像素：0 成功，1 容量不足。
EM_JS(int, zhu_font_pixels,
    (unsigned int code, float *info, unsigned char *out, unsigned int len), {
    const zhuFont = Module.zhu_font;
    const context = zhuFont.context;
    const text = String.fromCodePoint(code);
    const metrics = context.measureText(text);
    const left = Math.floor(-metrics.actualBoundingBoxLeft);
    const top = Math.ceil(metrics.actualBoundingBoxAscent);
    const width = Math.ceil(metrics.actualBoundingBoxRight) - left;
    const height = top + Math.ceil(metrics.actualBoundingBoxDescent);
    // Char 的内存顺序为 x、y、width、height、advance，基线上方的 y 为负。
    HEAPF32[info >> 2] = left;
    HEAPF32[(info >> 2) + 1] = -top;
    HEAPF32[(info >> 2) + 2] = width;
    HEAPF32[(info >> 2) + 3] = height;
    HEAPF32[(info >> 2) + 4] = metrics.width;
    if (width === 0 || height === 0) return 0;
    // 包含一像素透明边框，Zig 可以将整块数据直接写入上传缓冲。
    const copyWidth = width + 2;
    const copyHeight = height + 2;
    // 容量不足时不写入像素，等待调用方扩容后再次调用。
    if (copyWidth * copyHeight * 4 > len) return 1;

    // 修改画布尺寸会重置绘图状态，恢复 metrics 已设置的字体和字号。
    zhuFont.canvas.width = copyWidth;
    zhuFont.canvas.height = copyHeight;
    context.font = zhuFont.style;
    context.textBaseline = "alphabetic";
    context.fillStyle = "white";
    context.fillText(text, 1 - left, 1 + top);
    const data = context.getImageData(0, 0, copyWidth, copyHeight).data;
    HEAPU8.set(data, out);
    return 0;
});

// 查询主要指针是否为粗略指针，初始化时用于推测是否缺少实体键盘。
EM_JS(int, zhu_coarse_pointer, (void), {
    return window.matchMedia('(pointer: coarse)').matches ? 1 : 0;
});

extern void zhu_fetch_done(int lane, int size, int status);

// 让 emcc 导出完成入口，JS 只登记结果，下一帧再执行资源回调。
EMSCRIPTEN_KEEPALIVE void zhu_fetch_complete(int lane, int size, int status) {
    zhu_fetch_done(lane, size, status);
}

// 每个槽位只保留一个请求，停止后禁止写入已释放的 Wasm 缓冲区。
EM_JS(void, zhu_fetch_start,
    (int lane, const char *path, unsigned char *out, int len), {
    const jobs = Module.zhu_fetch_jobs ||= [];
    const job = new AbortController();
    jobs[lane] = job;
    fetch("assets/" + UTF8ToString(path), { signal: job.signal })
    .then(async response => {
        if (!response.ok) {
            if (jobs[lane] === job) {
                jobs[lane] = null;
                _zhu_fetch_complete(lane, 0, 1);
            }
            return;
        }
        const data = new Uint8Array(await response.arrayBuffer());
        if (jobs[lane] !== job) return;
        jobs[lane] = null;
        if (data.length > len) {
            _zhu_fetch_complete(lane, 0, 2);
        } else {
            HEAPU8.set(data, out);
            _zhu_fetch_complete(lane, data.length, 0);
        }
    }).catch(() => {
        if (jobs[lane] !== job) return;
        jobs[lane] = null;
        _zhu_fetch_complete(lane, 0, 3);
    });
});

// 资源系统关闭时中止全部请求，旧 Promise 不再访问缓冲区。
EM_JS(void, zhu_fetch_stop, (void), {
    const jobs = Module.zhu_fetch_jobs || [];
    for (let lane = 0; lane < jobs.length; lane++) {
        const job = jobs[lane];
        jobs[lane] = null;
        if (job) job.abort();
    }
});

// 检查浏览器中是否存在存档。
EM_JS(int, zhu_file_exists, (const char *name), {
    const path = UTF8ToString(name);
    try {
        return window.localStorage.getItem(path) !== null;
    } catch (err) {
        console.error("check file failed:", path, err);
        return false;
    }
});

// 读取存档字节，缓冲区不足时返回所需长度的负值。
EM_JS(int, zhu_file_load, (const char *name, unsigned char *out, int len), {
    const path = UTF8ToString(name);
    try {
        const base64 = window.localStorage.getItem(path);
        if (!base64) return 0;
        const binary = atob(base64);
        if (binary.length > len) return -binary.length;
        for (let i = 0; i < binary.length; i++) {
            HEAPU8[out + i] = binary.charCodeAt(i);
        }
        return binary.length;
    } catch (err) {
        console.error("load file failed:", path, err);
        return 0;
    }
});

// 将存档字节编码为 Base64，保存到浏览器。
EM_JS(int, zhu_file_save, (const char *name, const unsigned char *data, int len), {
    const path = UTF8ToString(name);
    let text = "";
    for (let pos = data; pos < data + len; pos += 0x8000) {
        const end = Math.min(pos + 0x8000, data + len);
        const chars = new Array(end - pos);
        for (let i = pos; i < end; i++) {
            chars[i - pos] = String.fromCharCode(HEAPU8[i]);
        }
        text += chars.join("");
    }
    try {
        window.localStorage.setItem(path, btoa(text));
        return 0;
    } catch (err) {
        console.error("save file failed:", path, err);
        return 1;
    }
});
