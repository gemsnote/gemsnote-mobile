# Android 分享接收

`LaunchActivity` 接收外部入口，完成引擎准备后将原始 Intent（含 MIME、ClipData、extras 与 URI 授权标志）转交 `MainActivity`。后者处理 `ACTION_SEND` / `ACTION_SEND_MULTIPLE` 的文本、图片和附件（通配 MIME）。支持 `EXTRA_TEXT` 单项/列表，以及 `EXTRA_STREAM` 或 ClipData 中的文件 URI。纯文本和 Markdown 文件严格按 UTF-8 解码；其余内容按二进制原件保存。

- 每批最多 8 项，持久收件箱总容量也是 8 项，文本单项最多 256 KiB UTF-8，二进制单文件最多 32 MiB。私有分享暂存目录总量最多 96 MiB（含正在读取的文件），超限拒绝，不淘汰待导入原件。
- 文件只从 `content://` URI 读取；Android 检查来源授予的 URI 读取权限。
  拒绝应用自身的 provider，不能从外部分享入口读取应用内部文件。
- 不需要存储/媒体读取权限，不保存长期 URI 授权，也不读取任意文件路径。
- `SharedTextDecoder` 严格验证 UTF-8、拒绝 NUL/空白/非法编码，支持 UTF-8 BOM，
  保留正文和换行，不执行或下载正文链接。标题限制按 Unicode 码点计算。
- 文件在最多 2 个后台 worker 中读取；每批 15 秒后提示超时并拒绝迟到结果。
  无响应 provider 的系统 I/O 不保证立即中止，其 worker 位置在实际返回前仍占用，
  避免无界线程/任务增长。普通文本接收不依赖文件 worker。
- 同一批全部读取和验证成功后，才在主线程检查最新队列剩余容量并一次 commit。
  任一文件失败、超限或容量不足，整批不新增记录。文件附带的 `EXTRA_TEXT`
  作为独立待导入文本保留，也计入容量，避免静默丢弃说明文字。
- 二进制文件以随机 ID 存在私有 `filesDir/shared_resources`，不使用来源文件名构造路径。文件 fsync 完成后才能入队；导入确认后移除原件，下次初始化或入队清理无队列引用且不在读取中的残留文件。
- Flutter 只在用户选择账号后按 ID/accountKey 读取已认领原件，并验证长度；笔记与待上传任务同一数据库事务保存，失败全部回滚，不提前 acknowledge。PNG/JPEG 可规范化为正文图片，或取消勾选保留为普通附件。未联网、不自动上传；后续上传复用 API2 和资源队列。
- 稳定 ID 在读取前生成；打开工作区后，沿用账号/笔记本确认、claim、
  本地幂等导入、acknowledge 和 API2 同步。切换账号不自动改投已绑定分享。
- Activity 重建不重放已接收 intent；读取完成时通知当前 Flutter engine。
  保存成功前进程若被系统杀死，未完成的读取不能保证恢复，需要来源重新分享；
  成功提示只在本机队列持久写入完成后显示。

## 验证

```sh
bash scripts/test_android_share_decoder.sh
```

脚本使用 `JAVA_HOME`，未设置时使用 Android Studio 自带 JDK；编译生产 Java 解码器和资源暂存模块。
覆盖 UTF-8/BOM、多字节跨块、恰好达限/超限、无限长度流读取界限、来源读取失败、
中断、NUL/空白和 Unicode 标题；资源测试覆盖二进制保真、重开读取、路径拒绝、空/超限文件、总容量、取消清理和读取期间的残留清理互斥。Android debug APK 构建验证 Kotlin/Java 集成和 Manifest。

### 真实跨应用来源与导入

2026-10-20 在 Android 35 / Pixel 9 上，通过独立测试来源应用和系统分享面板，
验证了非导出 provider 的临时 URI 授权，以及一次发送 PNG、二进制文件、GIF、
带 BOM 的 UTF-8 文本和说明文字。收件箱一次新增 5 条，PNG/bin/GIF 原件逐字节
相同，中文/emoji/换行保留且去除 BOM；应用重新启动后队列不变。有效 PNG 加空文件的
失败批次在完整超时窗口内未新增任何记录，暂存目录亦无残留文件。

随后真实原生通道和生产导入对话框 **1 项设备测试通过（5 类内容循环，16 秒）**：
认领前/错误账号不能读原件、不能重新认领到其他账号；编辑标题/正文并选择笔记本后，
离线笔记和资源任务保存到独立真实 SQLite。注入首次确认清理失败，数据库重开后重试
不覆盖后续编辑、不重复导入，再通过对话框重试清理。最终宿主确认收件箱和私有原件
目录均为空。不访问真实服务器，不代表其他来源或上传同步已经通过。

复现需要 macOS、Android SDK 36/build-tools 36.0.0、JDK，以及英文系统的专用模拟器。
先安装并启动普通 debug APK，退出账号并确保分享收件箱为空，然后从 mobile-app 执行：

```sh
bash scripts/build_android_share_fixture.sh
# 使用上一步输出的 fixture.apk 路径：
python3 scripts/test_android_share_ui.py emulator-5554 /path/to/fixture.apk
# 使用 UI 验证输出的 records.json 路径：
python3 scripts/test_android_share_import.py emulator-5554 /path/to/records.json
```

如已有失效 JAVA_HOME，为构建及导入命令设置 Android Studio JDK。构建脚本只生成临时
来源 APK，不更改生产工程；UI 脚本只替换来源测试应用，拒绝非空收件箱，不清空目标
应用数据。UI 验证保留五条夹具供导入验证，导入脚本严格比对已核验记录后才执行；
失败保留现场，不删除未知记录。共用导入场景在 `native_share_import_scenario.dart`，
Android/iOS 保持各自测试入口；设备运行使用 `--no-uninstall`。
结束后重新构建并安装普通 `lib/main.dart` APK，避免保留测试入口。

尚待设备验收：更多来源应用/无授权 URI、文件选择器和云端 provider、
多项与混合说明文字、满队列、超时、后台/旋转/进程终止、与导入确认同时读取文件。
已有多项与说明文字证据只覆盖本地测试 provider，不能推广到全部来源。
JVM 测试及 APK 编译不代表上述设备用例已通过。

接口依据：[Android 接收其他应用分享](https://developer.android.com/develop/ui/compose/sharing/receive)。
