# 设计约定

- 批处理自动分批只处理纹理视图切换，不根据采样器或其它状态分批。
- ZhuYu 引擎不编写测试。

# 待处理问题

## 1. 考虑使用 `std.Io` 替换 fetch 逻辑

- 状态：暂缓替换，先保留现有实现。以下限制适用于项目使用的 Zig 0.17
  标准库和当前引擎实现；后续上游变化以 Codeberg 为准。
- 替换范围：`src/internal/fetch.zig` 的桌面文件读取和线程唤醒已经使用
  `std.Io`，剩下的主要是自建请求调度、结果交接与平台适配。
- 帧循环不能阻塞：`std.Io.async` 允许在调用线程同步执行任务，当前
  `Threaded` 后端在单线程、资源不足或达到并发限制时可能退回同步执行。
  若改用 `std.Io.concurrent`，还需处理 `ConcurrencyUnavailable`，不能把
  文件读取或等待未完成任务放进主线程的每帧更新。
- 回调仍须回到主线程：当前 `assets.update()` 调用 `fetch.dowork()`，再执行
  图片上传 GPU、音频处理和缓存修改。换成标准库任务后，仍需完成结果队列
  和每帧非阻塞分发，不能在工作线程直接调用现有资源回调。
- Web 不能直接改为文件读取：资源通过 `src/internal/web.c` 中的 JavaScript
  `fetch()` 下载，依赖浏览器事件循环、Wasm 内存写入和 `AbortController`。
  `std.Io.Dir` 的文件读取不能直接替代这条网络加载路径，仍需浏览器适配。
- Android 仍需 APK 资源适配：当前通过 `AAssetManager_open` 和 `AAsset_read`
  读取包内资源，不是打开普通的 `assets` 目录。标准库任务可以调度这段读取，
  但不能直接消除 NDK 接口；外部读取也不会自动获得标准库的取消点。
- 所有权与退出顺序需要重做：当前使用 4 个槽位限制在途请求，路径和缓冲区
  由主线程分配、移交和释放，后台线程只读取；引擎的内存统计没有加锁。
  替换时须继续限制并发与缓冲区大小，并在任务退出、浏览器请求失效后，
  再释放路径和缓冲区，防止后台任务或旧回调继续访问已释放内存。
- 后续评估：可以先验证桌面端的任务调度替换，再考虑跨平台统一；确认帧耗时、
  内存峰值、关闭期间的资源释放，以及第 6 项所述的 WASM 体积问题后再决定。

## 2. Zig 下载依赖失败

- 错误：`HttpConnectionClosing`。
- 原因：Zig 0.16 通过 HTTP 代理建立 `CONNECT` 隧道后未升级为 TLS。
- 上游修复：跟踪 Zig PR [#36737](https://codeberg.org/ziglang/zig/pulls/36737)，目前尚未合并。
- 临时方案：先取消代理环境变量并直接连接；如果直连失败，则启用代理软件的 TUN 模式，并继续让 Zig 不使用显式 HTTP 代理。

## 3. 部署到 Cloudflare

- 待做：将项目的 Web/WASM 构建产物部署到 Cloudflare。

## 4. VS Code Remote SSH 找不到 Zig/ZLS

- `zig.path`、`zig.zls.path` 是 `machine-overridable` 设置；Windows 用户设置不会被远程 Linux 继承，应写入 `/root/.vscode-server/data/Machine/settings.json`，值分别为 `zig`、`zls`，并设置 `zig.zls.enabled` 为 `on`。
- Zig 扩展运行在远程 Linux；确保 `/root/.bashrc` 将 `/root/software/zig` 加入 `PATH`。仅写 `/etc/profile` 无法覆盖 VS Code Remote SSH 的非登录 shell。
- PATH 变更后使用 `Remote-SSH: Kill VS Code Server on Host...` 再重新连接；仅关闭或重载窗口可能继续使用旧的 Server 进程。

## 6. `std.Io` 增大 WASM 体积

- 上游跟踪：Zig issue [#31421](https://codeberg.org/ziglang/zig/issues/31421)。
- 原因：`std.Io` 的函数指针表使未使用的功能无法被充分移除，增大构建产物。
- 状态：截至 2026-10-08，issue 仍为 open；最新评论（2026-10-05）反馈
  Zig 0.17 仍存在此问题。此前空 `main` 的局部修复没有完整解决此问题。
- 项目表现：demo 的 Zig 0.17 ReleaseSafe WASM 中，按函数符号归属统计，
  `std.Io` 代码约 75.5 KiB；其中包含实际需要的功能，不能全部视为可删除开销。
- 待做：跟踪上游修复；修复发布后重新构建并比较 WASM 体积，确认实际收益。
