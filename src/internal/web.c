#include <emscripten.h>

// 存档函数需要将 Wasm 中的路径转换为 JavaScript 字符串。
EM_JS_DEPS(zhu_storage, "$UTF8ToString");

// 让静态库链接器带入本文件中的 JavaScript 函数描述。
void zhu_web_keep(void) {}

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
