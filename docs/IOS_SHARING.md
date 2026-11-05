# iOS 分享接收

当前实现纯文本、HTTP(S) 网页链接、图片、文件和多项接收。
这是原生 Share Extension，不依赖 Flutter 引擎在后台运行，也不在扩展内登录或联网。

## 使用流程

1. 在其他应用的系统分享面板选择 Gemsnote，确认只读预览后保存。
2. 打开 Gemsnote；工作区初始化或回到前台时读取收件箱。
3. 点击待处理分享，确认服务器、账号、笔记本后导入，也可明确丢弃。
4. 本地导入成功后才移除收件记录。后续上传沿用现有 API2 同步。

扩展不会自动启动主应用。队列最多 8 项，每项文本最多 256 KiB UTF-8，
每批资源总计最多 32 MiB。每个输入保留为独立条目，由主应用逐项导入；
满队列、无效输入、读取失败或存储失败会提示，不能以分享完成掩盖写入失败。
整批校验通过后才发布队列，不截断多个输入。网页链接按文本保存，不自动访问目标。

扩展优先接收 PNG/JPEG 表示。实际为 PNG/JPEG、8 MiB 内且宽高均不超过
4096 像素的图片进入正文图片流程；HEIC/GIF、超限图片及其他文件保留原件作为附件。
提供者临时文件在回调结束前读取，资源保存于 App Group 私有目录。
读取从已打开的普通文件描述符分块进行，并遵守整批剩余的资源容量；
超限、空文件或读取中尺寸发生变化时拒绝本批，不依赖事先的文件大小检查。
主应用认领账号后才允许通过通道读取原件；确认导入或明确丢弃后清理。
分享预览、操作和错误提示沿用主应用的 `system/zh/en` 选择。
纯文本提供者的 String、Data 或临时文件 URL，以及 `.txt`/`.md`/`.markdown`
文件 URL，按严格 UTF-8、最多 256 KiB 读取为正文并去除开头 BOM。
无效编码、空白文本、NUL、超限和非普通文件会拒绝整批，不读取远程 URL。

## 工程和签名

- Runner 依赖并嵌入 `ShareExtension.appex`，扩展仅使用原生框架。
- Runner bundle ID 为 `com.github.gemsnote`，扩展为 `com.github.gemsnote.ShareExtension`。
- 两个 target 的 Debug/Release/Profile 共用 `Shared/AppGroup.entitlements`，
  App Group 来自项目级 `GEMSNOTE_APP_GROUP`，默认 `group.com.github.gemsnote`。
- 在 Apple Developer 账号中注册相应 App Group，把两个 App ID 都加入该组，
  并为两个 target 配置同一开发团队和支持该权限的 provisioning profile。
  使用自有 bundle ID 时也需配置匹配的扩展 ID 和有权使用的 App Group。
- 两个 Info.plist 的 `GemsnoteAppGroup` 与 entitlement 使用相同 build setting；
  扩展版本从 Flutter Generated.xcconfig 读取，与主应用一致。
- 扩展不共享 token、密码或 Keychain。导入账号由主应用确认后绑定；
  已绑定条目不能因切换账号而被改投，稳定记录 ID 复用现有幂等导入。

`Shared/SharedTextStore.swift` 使用 App Group 内独立锁文件和 `flock`，
在锁内读取、校验、修改并原子替换 JSON。损坏的收件箱保留原文件并报错。
队列文件使用首次解锁后的数据保护。主应用方法通道在隐式 Flutter engine 初始化时注册。

## 验证

macOS Command Line Tools 即可运行存储测试：

```sh
bash scripts/test_ios_share_store.sh
```

它编译生产存储源码，验证持久化、容量和字节限制、账号绑定、幂等、损坏数据保护、
整批资源保存与失败、资源读取隔离、清理和图片类型回退，
还覆盖提供者文件分块读取、容量边界、剩余批次不足和非普通文件拒绝，
并启动 8 个独立进程验证并发写入不丢记录。Flutter 的
`test/shared_text_inbox_test.dart` 覆盖 Android/iOS 默认启用和初始化/前台刷新路径。

Safari 分享及图片/文件批量接收可使用独立 Xcode UI 测试工程验证；测试需要未登录的测试模拟器、
已有 CocoaPods 的 xcodeproj Ruby gem、Python 3，以及空闲的本机 8765 端口。
先构建普通 Debug 模拟器应用（**不要加 `--no-codesign`**），再运行：

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh flutter build ios --simulator --debug
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh bash scripts/test_ios_share_ui.sh <simulator-id>
```

脚本安装当前构建，启动仅监听 127.0.0.1 的网页夹具，实际操作 Safari 分享面板。
另外生成仅用于测试的 SharingFixture 应用，通过真实 UIActivityViewController
同时分享 PNG、二进制文件、GIF 与纯文本文件，检查正文图片/附件分类、
资源与来源文件逐字节一致，以及文本文件完整解码为正文。
另一用例发送有效 PNG 加空文件，确认错误提示、保存禁用、取消可用和没有部分记录。
语言用例通过主应用真实语言菜单依次选择英文、中文、英文，每轮终止并重新启动主应用，
再从独立来源应用打开分享扩展，精确核对保存/取消和导入提示语言。
结束通过同一菜单恢复原偏好，宿主核对 App Group 偏好已恢复；
三轮全部取消，宿主确认没有新增语言夹具记录。系统分享目标兼容“Gemsnote”和
“珠玑笔记”两种正式名称，不把系统选择的应用名称当成应用内语言偏好。
取消首次分享后再次保存同一测试 URL，重启主应用，检查真实 App Group 中仅有一条
完整且未认领的记录。全部测试均成功后，用生产存储代码确认移除本轮五个测试记录
及其资源，并清理来源应用本轮临时原件；不会清空其他收件记录。
失败时保留现场供排查；测试日志、截图附件和 xcresult 位于输出的临时目录，
可用 `IOS_UI_WORK_DIR` 指定专用目录复用编译缓存。脚本结束关闭其启动的网页服务。
测试当前针对 iOS 26 的中文/英文 Safari 紧凑工具栏，其他布局需适配测试定位。

### 原生收件箱到 Flutter 离线导入

使用已安装普通 Debug 应用、收件箱为空的测试模拟器执行：

```sh
FLUTTER_BIN=/path/to/flutter/bin/flutter \
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh bash scripts/test_ios_share_import.sh <simulator-id>
```

脚本通过生产 Swift 存储写入带唯一标识的文本、PNG 和二进制文件夹具，
再运行 Flutter 设备测试。测试使用真实 App Group 通道和独立 SQLite 文件，
验证认领前资源不可读、其他账号不能读取或再次认领、离线导入后产生待同步任务、
数据库重开后重试不覆盖后续编辑，以及确认后原生记录/资源不可再读取。
测试还挂载生产导入对话框，编辑标题/正文、选择笔记本并保存。首次确认清理
通过测试回调注入失败，检查编辑已禁用、记录仍待确认；点击“重试清理”后
调用真实原生确认，且导入回调不重复执行。此处是可控故障注入，不代表
已制造真实的系统磁盘或进程故障。
网络客户端明确拒绝任何请求，不使用真实账号。此测试验证对话框、存储桥接和
仓库导入；不能替代工作区完整导航、系统来源分享测试或真实 API2 上传验收。

已有收件记录时脚本拒绝运行，不清空收件箱。成功时仅确认本轮三个记录并清理
独立数据库；失败时脚本不主动清理剩余夹具，日志保留在输出的临时目录。
脚本已指定 `--no-uninstall`，避免 Flutter 运行器结束时卸载应用和 App Group 数据。
共用导入场景位于 `native_share_import_scenario.dart`，iOS 保留原有入口和三条夹具；
测试中断时仍应检查剩余记录，不清空其他来源的内容。
测试会安装集成测试入口，完成后使用 DEVELOPMENT.md 中的模拟器构建命令
显式指定 `--target lib/main.dart`，重新安装普通应用。

2026-10-20 已通过 UIKit 类型检查和完整 iOS Debug 模拟器构建，
并在 iPhone 12 mini / iOS 26.3 启动主应用，确认中文登录页显示。
设备集成测试已通过主应用真实通道的 App Group 收件箱访问检查；
该检查不认领或删除现有条目。后续独立 Safari UI 测试已通过取消后重开、保存、
主应用重启后唯一 URL 记录持久化；自有 UIKit 界面实际显示中文“保存/取消”。
后续 SharingFixture 来源应用的 PNG/二进制文件/GIF/纯文本文件混合分享及空文件失败批次也通过，
分类、原件字节、文本文件完整正文和失败批次无部分记录均已核对；
新增跨进程语言验证后共 **4 项 UI 测试通过（122 秒）**，
其中英文→中文→英文、主应用重启及扩展更新专项为 63 秒。
原语言偏好恢复、取消不写收件箱和本轮五条成功分享夹具清理均经宿主核对。
测试不包含登录后的笔记导入、其他提供者、HEIC 或超限输入。
这些检查不能替代系统分享与真机验收。仍需检查：

- Release/Profile 扩展嵌入、签名、版本一致性（发布暂缓）。
- Safari 之外的纯文本和文件/图片/多项来源；已登录、后台到前台等生命周期。
- 其他来源取消、读取失败、超时、超限、满队列、系统终止扩展后重试。导入对话框编辑与一次清理失败重试已有设备测试。
- 工作区不同账号切换、真实系统确认失败、连续点击及完整导航生命周期；原生跨账号拒绝和受控重试幂等已有设备测试。
- 扩展与主应用同时保存/确认、设备锁定与解锁后的数据保护行为。
- HEIC 附件回退、其他提供者临时文件生命周期和扩展内存限制；GIF 原件回退已由系统 UI 测试验证。

实现依据：[Apple 扩展共享数据](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)、
[Apple 激活规则](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html)、
[Flutter UIScene 与隐式引擎通道注册](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)。
