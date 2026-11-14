// 浏览器宿主接口，通过 Emscripten --js-library 注入。
mergeInto(LibraryManager.library, {
    // DateTime 按声明顺序保存七个 i32，偏移秒数采用东区为正的约定。
    zhu_local_time: function(seconds, out) {
        const date = new Date(seconds * 1000);
        const local = new Date(0);
        local.setUTCFullYear(date.getFullYear(), date.getMonth(), date.getDate());
        const hour = date.getHours();
        const minute = date.getMinutes();
        local.setUTCHours(hour, minute, date.getSeconds(), 0);
        HEAP32[out >> 2] = date.getFullYear();
        HEAP32[(out >> 2) + 1] = date.getMonth() + 1;
        HEAP32[(out >> 2) + 2] = date.getDate();
        HEAP32[(out >> 2) + 3] = hour;
        HEAP32[(out >> 2) + 4] = minute;
        HEAP32[(out >> 2) + 5] = date.getSeconds();
        HEAP32[(out >> 2) + 6] = (local.getTime() - date.getTime()) / 1000;
    },

    // 创建离屏画布并保存唯一的字体状态。
    zhu_font_open__deps: ["$UTF8ToString"],
    zhu_font_open: function(family, weight) {
        const canvas = typeof OffscreenCanvas !== "undefined"
            ? new OffscreenCanvas(1, 1)
            : document.createElement("canvas");
        const context = canvas.getContext("2d", { willReadFrequently: true });
        if (!context) return 1;
        // 字体系统只允许打开一个字体，直接保存供后续调用复用。
        Module.zhu_font = {
            canvas,
            context,
            family: UTF8ToString(family),
            weight,
        };
        return 0;
    },

    // 释放浏览器保存的字体和离屏画布引用。
    zhu_font_close: function() {
        Module.zhu_font = null;
    },

    // 设置像素字号并读取基线和行高度量。
    zhu_font_metrics: function(size, out) {
        const zhuFont = Module.zhu_font;
        zhuFont.style = zhuFont.weight + " " + size + "px " + zhuFont.family;
        zhuFont.context.font = zhuFont.style;
        const metrics = zhuFont.context.measureText("国Mg");
        const ascent = metrics.fontBoundingBoxAscent
            ?? metrics.actualBoundingBoxAscent;
        const descent = metrics.fontBoundingBoxDescent
            ?? metrics.actualBoundingBoxDescent;
        HEAPF32[out >> 2] = ascent;
        HEAPF32[(out >> 2) + 1] = descent;
        HEAPF32[(out >> 2) + 2] = Math.max(size, ascent + descent);
    },

    // 缓冲不足时保留像素，扩容后再次调用只拷贝，不重新生成。
    zhu_font_pixels: function(code, info, out, len) {
        const zhuFont = Module.zhu_font;
        if (zhuFont.pixels) {
            // 扩容后使用当前 Wasm 内存视图拷贝暂存像素。
            HEAPU8.set(zhuFont.pixels, out);
            zhuFont.pixels = null;
            return 0;
        }
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

        // 修改画布尺寸会重置绘图状态，恢复 metrics 已设置的字体和字号。
        zhuFont.canvas.width = copyWidth;
        zhuFont.canvas.height = copyHeight;
        context.font = zhuFont.style;
        context.textBaseline = "alphabetic";
        context.fillStyle = "white";
        context.fillText(text, 1 - left, 1 + top);
        const pixels = context.getImageData(0, 0, copyWidth, copyHeight).data;
        for (let i = 0; i < pixels.length; i += 4) {
            const a = pixels[i + 3];
            pixels[i] = a;
            pixels[i + 1] = a;
            pixels[i + 2] = a;
        }
        zhuFont.pixels = pixels;
        if (zhuFont.pixels.length > len) return 1;
        // 扩容可能更换 Wasm 内存视图，拷贝时读取当前视图。
        HEAPU8.set(zhuFont.pixels, out);
        zhuFont.pixels = null;
        return 0;
    },

    // 通过媒体查询判断主要指针是否为粗略指针。
    zhu_coarse_pointer: function() {
        return window.matchMedia("(pointer: coarse)").matches ? 1 : 0;
    },

    // 每个槽位只保留一个请求，网络或 5xx 失败时重试一次，完成后将结果通知 Wasm。
    zhu_fetch_start__deps: ["$UTF8ToString"],
    zhu_fetch_start: function(lane, path) {
        const jobs = Module.zhu_fetch_jobs ||= [];
        const job = new AbortController();
        const url = "assets/" + UTF8ToString(path);
        jobs[lane] = job;
        (async () => {
            for (let i = 0; i < 2; i++) {
                try {
                    const resp = await fetch(url, { signal: job.signal });
                    if (resp.ok) {
                        const buf = await resp.arrayBuffer();
                        const data = new Uint8Array(buf);
                        if (jobs[lane] !== job) return;
                        jobs[lane] = null;
                        const out = _zhu_fetch_alloc(lane, data.length);
                        HEAPU8.set(data, out);
                        _zhu_fetch_done(lane, 0);
                        return;
                    }
                    if (resp.status < 500 || i === 1) {
                        if (jobs[lane] === job) {
                            jobs[lane] = null;
                            _zhu_fetch_done(lane, 1);
                        }
                        return;
                    }
                } catch {
                    if (jobs[lane] !== job) return;
                    if (i === 1) {
                        jobs[lane] = null;
                        _zhu_fetch_done(lane, 3);
                        return;
                    }
                }
            }
        })();
    },

    // 中止全部请求，旧 Promise 不再访问已释放的缓冲区。
    zhu_fetch_stop: function() {
        const jobs = Module.zhu_fetch_jobs || [];
        for (let lane = 0; lane < jobs.length; lane++) {
            const job = jobs[lane];
            jobs[lane] = null;
            if (job) job.abort();
        }
    },

    // 检查浏览器中是否存在存档。
    zhu_file_exists__deps: ["$UTF8ToString"],
    zhu_file_exists: function(name) {
        const path = UTF8ToString(name);
        try {
            return window.localStorage.getItem(path) !== null ? 1 : 0;
        } catch (err) {
            console.error("check file failed:", path, err);
            return 0;
        }
    },

    // 读取存档字节，缓冲区不足时返回所需长度的负值。
    zhu_file_load__deps: ["$UTF8ToString"],
    zhu_file_load: function(name, out, len) {
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
    },

    // 将存档字节编码为 Base64，保存到浏览器。
    zhu_file_save__deps: ["$UTF8ToString"],
    zhu_file_save: function(name, data, len) {
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
    },
});
