# 设计约定

- 批处理自动分批只处理纹理视图切换，不根据采样器或其它状态分批。
- ZhuYu 引擎不编写测试。

# 待处理问题

## 1. `ImmDisableIME` 跨平台链接

- Linux 测试链接失败：`undefined symbol: ImmDisableIME`。
- 原因：仅 Windows 可用的 extern 声明进入了 Linux 构建。
- 当前修复：让声明和调用仅在 Windows 目标存在，改动保留。
- 待做：跟踪 Zig PR [#36126](https://codeberg.org/ziglang/zig/pulls/36126)（提交 `2c21088ff`）；其 Windows extern 新组织方式合并并随 Zig 发布后，升级并改用上游定义。
- 待做：跟踪 Zig 提案 [#30873](https://codeberg.org/ziglang/zig/issues/30873)；`@extern` / `@export` 新语法确定并发布后，迁移当前 `extern "Imm32" fn` 声明。该提案目前尚未标记为 accepted。

## 2. Zig 下载依赖失败

- 错误：`HttpConnectionClosing`。
- 原因：Zig 0.16 通过 HTTP 代理建立 `CONNECT` 隧道后未升级为 TLS。
- 上游修复：跟踪 Zig PR [#36737](https://codeberg.org/ziglang/zig/pulls/36737)，目前尚未合并。
- 临时方案：先取消代理环境变量并直接连接；如果直连失败，则启用代理软件的 TUN 模式，并继续让 Zig 不使用显式 HTTP 代理。

## 3. Zig 0.16 WASM 编译

- `wasm32-emscripten` 编译会从默认入口、panic 或日志路径引入 `std.Io.Threaded`，产生类型错误。
- `ReleaseSafe` 同样受影响，并非仅 Debug。
- 上游：Zig [#31849](https://codeberg.org/ziglang/zig/issues/31849) 已由 [#31850](https://codeberg.org/ziglang/zig/pulls/31850) 修复，但修复晚于 0.16.0；相关问题 [#31872](https://codeberg.org/ziglang/zig/issues/31872) 也已修复。
- 临时兼容：由 ZhuYu 的 Web 构建层提供专用 root wrapper，客户端继续使用自己的 `main.zig`，无需修改 `build.zig`；当前 Debug 与 ReleaseSafe 构建均已通过。
- 待做：升级到 Zig 0.17 并确认上游修复生效后，从引擎删除 `src/internal/web_main.zig` 及其构建包装，客户端无需修改。

## 4. 部署到 Cloudflare

- 待做：将项目的 Web/WASM 构建产物部署到 Cloudflare。

## 5. VS Code Remote SSH 找不到 Zig/ZLS

- `zig.path`、`zig.zls.path` 是 `machine-overridable` 设置；Windows 用户设置不会被远程 Linux 继承，应写入 `/root/.vscode-server/data/Machine/settings.json`，值分别为 `zig`、`zls`，并设置 `zig.zls.enabled` 为 `on`。
- Zig 扩展运行在远程 Linux；确保 `/root/.bashrc` 将 `/root/software/zig` 加入 `PATH`。仅写 `/etc/profile` 无法覆盖 VS Code Remote SSH 的非登录 shell。
- PATH 变更后使用 `Remote-SSH: Kill VS Code Server on Host...` 再重新连接；仅关闭或重载窗口可能继续使用旧的 Server 进程。
