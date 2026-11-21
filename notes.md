# 设计约定

- 批处理自动分批只处理纹理视图切换，不根据采样器或其它状态分批。
- ZhuYu 引擎不编写测试。
- 图片实例不得超过 64 字节；新增字段的方案必须同时说明减少哪些字段。

# 待处理问题

## 1. 考虑使用 `std.Io` 任务替换文件请求调度

- 状态：暂缓替换，先保留现有实现。以下限制适用于项目使用的 Zig 0.17
  标准库和当前引擎实现；后续上游变化以 Codeberg 为准。
- 替换范围：`src/internal/fetch.zig` 的桌面文件读取和线程唤醒已经使用
  `std.Io`，剩下的主要是自建请求调度、结果交接与平台适配。
- 帧循环不能阻塞：`std.Io.async` 允许在调用线程同步执行任务，当前
  `Threaded` 后端在单线程、资源不足或达到并发限制时可能退回同步执行。
  若改用 `std.Io.concurrent`，还需处理 `ConcurrencyUnavailable`，不能把
  文件读取或等待未完成任务放进主线程的每帧更新。
- 回调仍须回到主线程：当前 `assets.update()` 调用 `fetch.update()`，再执行
  图片上传 GPU、音频处理和缓存修改。换成标准库任务后，仍需完成结果队列
  和每帧非阻塞分发，不能在工作线程直接调用现有资源回调。
- Web 不能直接改为文件读取：资源通过 `src/internal/web.zig` 中的 JavaScript
  `fetch()` 下载，依赖浏览器事件循环、Wasm 内存写入和 `AbortController`。
  `std.Io.Dir` 的文件读取不能直接替代这条网络加载路径，仍需浏览器适配。
- Android 仍需 APK 资源适配：当前通过 `AAssetManager_open` 和 `AAsset_read`
  读取包内资源，不是打开普通的 `assets` 目录。标准库任务可以调度这段读取，
  但不能直接消除 NDK 接口；外部读取也不会自动获得标准库的取消点。
- 所有权与退出顺序需要保留：当前使用一个后台读取线程和 4 个槽位；路径由
  主线程复制，文件缓冲由后台线程按实际长度分配，回调后由主线程释放。
  Web 缓冲由浏览器响应回调分配，也由主线程在资源回调后释放。
  槽位通过原子状态交接所有权，内存统计使用原子操作，各项不保证同一时刻。
  替换时须继续限制在途请求数量，并在任务退出、浏览器请求失效后，
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

## 8. 不同相机下非等比缩放与旋转的补偿

- 状态：低优先级，待处理，暂不修改实现。
- 触发：图片指定的相机与批次相机之间存在非等比缩放差异，并且图片有旋转。
- 原因：当前先补偿图片尺寸、再旋转，最后应用批次相机缩放，无法正确抵消。
- 示例：视口为 1:1，批次相机倍率为 `(2, 1)`，使用窗口相机绘制
  `100 × 50` 的图片并旋转 90°，应显示为 `50 × 100`，当前得到 `100 × 50`。
- 约束：实例不得超过 64 字节，不因移动相机或穿插绘制 UI 而额外分批。
- 候选方向：结合现有斜切字段合成相机补偿与图片变换，
  不增加独立的相机补偿字段；具体计算尚待验证。

## 9. 默认使用预乘透明度渲染

- 状态：待做，仅记录方案，暂不实现。
- 方向：参考 PixiJS，创建流水线时默认采用预乘透明度混合。
- 混合：RGB 的源因子使用 `ONE`，目标因子使用 `ONE_MINUS_SRC_ALPHA`；
  Alpha 保持现有的 `ONE` 和 `ONE_MINUS_SRC_ALPHA`。
- 着色器：普通图片 shader 保持不变，继续将纹理采样结果与顶点颜色相乘。
- 顶点颜色：在 CPU 端将 RGB 乘以 Alpha，Alpha 本身保持不变。
- 图片数据：预乘发生在图片加载解码阶段还是资源打包阶段，尚未决定。

- 字体。 普通字体的纹理也要符合预乘约定；MSDF 的透明度在 shader 中生成，如果使用预乘流水线，输出 RGB 也必须乘以生成的覆盖率。因此，“shader 不变”目前确定适用于普通图片。
- 半透明清屏色。 如果离屏目标保存预乘结果，清屏颜色也要预乘。全透明黑色和不透明颜色不受影响。

## 10. Position 位置对齐

- 状态：暂缓，尚未实现；出现实际画面问题后再评估，不提前增加模式。
- 当前已有：`snap` 开关对最终顶点分别取整；
  `camera.snap` 只对渲染平移取整，不修改相机的逻辑坐标。
- 待解决场景：顶点分别取整可能改变字形或图片的尺寸，以及旋转、斜切后的
  形状；只有实际需要保持形状并对齐位置时，才考虑 Position 模式。
- 候选方案：对变换后的局部左上角计算像素取整偏移，所有顶点应用同一偏移，
  保持图片尺寸和形状；对齐依据当前渲染目标的实际视口像素。
- 文字限制：逐字形计算偏移只能保持单个字形尺寸，仍可能改变字距；
  若需要保持整段文字的相对布局，应评估整段共用偏移。
- 成本：顶点 shader 需要额外还原、投影参考点并计算偏移，同一实例会重复
  计算四次；重新引入前，应结合实际画面收益与 GPU 耗时决定是否值得。
- 约束：实例保持不超过 64 字节；若需要枚举，可复用现有对齐字节，
  不增加四角分别配置；不以模式数量或源码运算次数直接推断实际性能。
- 边界：位置对齐无法消除非整数缩放造成的纹素宽窄不均。

## 11. Zig 缓存按时间清理后构建失败

- 需求：`/tmp` 持续清理旧文件；有效缓存继续复用，被淘汰的产物按需重新生成，
  不要求每次构建都清空缓存或重新生成所有资源。
- 本机配置：`ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache`；
  `/etc/tmpfiles.d/tmp.conf` 使用 `D /tmp 1777 root root 2d`，每天按时间清理。
- 原版验证（2026-11-21，Zig 0.17.1）：删除缓存产物、保留记录后，`Run`、
  `WriteFile`、`Options`、`ConfigHeader`、`ObjCopy`、`TranslateC` 仍报告缓存命中，
  随后因 `FileNotFound` 失败；Zig 可执行文件和 C 静态库的最终产物可以重新生成。
  这些结果来自各类型的最小验证，不代表已检查所有编译中间产物。
- 原因：部分生成步骤只校验输入和缓存记录，没有确认输出仍存在；按文件时间
  清理可能删除产物而保留记录。问题不只涉及 shader，也涉及音效包及生成配置。
- 上游跟踪：[Zig #30193](https://codeberg.org/ziglang/zig/issues/30193)，
  截至 2026-11-21 仍开放。[2026-01-22 的评论][zig-cache-clean-report]
  已报告按访问时间清理缓存后构建失败，并建议缺失时重建对应产物。
- 上游计划：提供 `zig gc`，按 LRU 淘汰缓存；先取得记录的非阻塞锁，删除对应
  `o/` 产物和记录后释放锁。缓存命中时未更新使用时间的问题仍待处理。
- 自动清理跟踪：[Zig #36858](https://codeberg.org/ziglang/zig/issues/36858)，
  同样仍开放，计划在 `--watch` 空闲期间清理。以上是上游设计，
  不是 Zig 0.17.1 已提供的功能。
- 原版的手动恢复：从 `FileNotFound` 报错中的 `/tmp/zig-cache/o/<hash>/`
  取得产物哈希，定位对应的 `h/` 记录，只使这条记录失效后重跑原构建命令。
  通过非阻塞文件锁清空记录内容，保留记录文件；若记录正在使用则不修改。
- 验证结果：六类失败产物均能通过上述定点恢复重新生成；`WriteFile` 目录中
  只删除一个文件、保留其他文件时也能恢复。未受影响的对照生成步骤仍命中缓存，
  执行次数保持为 1，没有因恢复失效记录而被强制重建。
- 收益：保留现有缓存路径和 `/tmp` 清理配置，不修改工具链，不清空整个缓存。
  代价：发生缺失时，需要手动定位记录并重试；这不是自动恢复所有缓存错误的方案。

定位记录时，把 `cache_hash` 换成报错中的产物哈希。下面使用此次 shader 为例：

```sh
cache_hash=355484ed415f5f6cd2105f438952548b
zig cache-cat /tmp/zig-cache/h/[0-9a-f]* | awk -v hash="$cache_hash" '
/\.input_hash/ {record = $3; gsub(/[",]/, "", record)}
/\.discovered_hash/ && index($0, "\"" hash "\"") {
    print "/tmp/zig-cache/h/" record
}'
```

把 `cache_record` 设为上一步打印的路径；以下路径同样仅用于此次 shader 示例。
成功清空记录后，回到失败的项目重跑原构建命令：

```sh
cache_record=/tmp/zig-cache/h/d1516e6ba8763c9d8790aa1218aaa8bd
flock -n "$cache_record" truncate -s 0 "$cache_record"
```

### 本机临时补丁（2026-11-21）

- 状态：已应用到 `/root/software/zig` 的 Zig 0.17.1；直接使用原构建命令即可。
  修改的是随工具链分发的源码，辅助程序会自动重新编译，不需要重编译 Zig 二进制。
- 范围：8 个文件，补丁增加 296 行、删除 13 行，包含注释和空行。
  未改缓存哈希算法或记录格式，有效缓存继续复用，缺失产物才触发对应步骤恢复。
- `lib/std/Build/Cache.zig`：增加命中哈希预览和转为缺失状态的接口；
  `TranslateC` 产物缺失时，在文件锁下仅清空匹配的编译器缓存记录。
- `lib/compiler/Maker/Step.zig`：共用的输出存在性和类型检查。
- `lib/compiler/Maker/Step/` 中的 `Run.zig`、`WriteFile.zig`、`Options.zig`、
  `ConfigHeader.zig`、`ObjCopy.zig`、`TranslateC.zig`：接入上述检查和局部恢复。
- 文件输出：命中时确认文件存在，包括 `ObjCopy` 的独立调试文件及捕获的
  stdout/stderr；文件缺失时重新生成，不把所有资源步骤改为每次执行。
- 目录输出：`WriteFile` 复用已有的输入遍历，检查应当复制或写入的具体路径。
  `Run` 的目录内容由外部程序决定，因此在成功生成后保存文件和目录清单，
  位于 `/tmp/zig-cache/output-lists/<产物哈希>`，命中时逐项检查。
  旧目录缓存没有清单，或清单本身被清理时，仅重新生成对应目录一次；之后继续缓存。
- 验证：六类缺失产物自动恢复；目录内部分文件缺失、整棵目录被删除、
  捕获的 stdout/stderr 被删除、输出清单被删除均通过。
  有效命中不改变产物 mtime，恢复后的下一次仍命中；未受影响的对照步骤只执行一次。
- 项目验证：TinyFarm 当前源码构建通过，120 个测试通过；只删除实际 shader
  产物后，构建自动恢复出相同内容，下一次构建显示 shader 命中缓存。
- 代价：命中时增加输出文件检查；`Run` 目录输出增加清单读取和逐项检查。
  `TranslateC` 只有缺失时才扫描记录并重试一次。不是完整的 Zig 缓存 GC，
  未验证编译器所有内部缓存；仍跟踪上游修复。
- 备份：`/root/software/zig-local-patches/cache-output-recovery-0.17.1/`。
  `original/` 保存原文件，`cache-output-recovery.patch` 保存完整修改，
  `metadata.json` 保存原版和补丁版 SHA-256，`verify.py` 保存独立验证程序。
  补丁在临时副本中完成正向和反向应用验证，两次均与记录的 SHA-256 一致。
- 恢复：`restore.py` 先核对 Zig 版本及文件 SHA-256，再恢复 8 个原文件；
  文件若在此补丁后被修改，脚本会停止，避免覆盖其他修改。
  备份位于持久目录，不随 `/tmp` 清理；本次未修改清理配置或缓存路径。

恢复原版前先检查，然后执行恢复；恢复也不会清空缓存：

```sh
patch_dir=/root/software/zig-local-patches/cache-output-recovery-0.17.1
python3 "$patch_dir/restore.py" --check
python3 "$patch_dir/restore.py"
```

重新验证补丁时执行：

```sh
python3 "$patch_dir/verify.py"
```

[zig-cache-clean-report]: https://codeberg.org/ziglang/zig/issues/30193#issuecomment-10077444
