#include <emscripten.h>

// 存档函数需要将 Wasm 中的路径转换为 JavaScript 字符串。
EM_JS_DEPS(zhu_storage, "$UTF8ToString");

// 让静态库链接器带入本文件中的 JavaScript 函数描述。
void zhu_file_keep(void) {}

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
