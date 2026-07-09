// 浏览器存档桥接，供 Zig 侧 extern 函数调用。
mergeInto(LibraryManager.library, {
  em_js_file_save: function(c_path, c_data, len) {
    var path = UTF8ToString(c_path);
    var chunkSize = 0x8000;
    var text = "";

    for (var pos = c_data; pos < c_data + len; pos += chunkSize) {
      var end = Math.min(pos + chunkSize, c_data + len);
      var chars = new Array(end - pos);

      for (var i = pos; i < end; i++) {
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

  em_js_file_load: function(c_path, out_buf, len) {
    var path = UTF8ToString(c_path);

    try {
      var base64 = window.localStorage.getItem(path);
      if (!base64) return 0;

      var binary = atob(base64);
      if (binary.length > len) return -binary.length;

      for (var i = 0; i < binary.length; i++) {
        HEAPU8[out_buf + i] = binary.charCodeAt(i);
      }
      return binary.length;
    } catch (err) {
      console.error("load file failed:", path, err);
      return 0;
    }
  },

  em_js_keep: function() {},
});
