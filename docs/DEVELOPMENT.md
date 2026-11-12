# 移动端开发

## 环境

- Flutter stable 3.47 或更高版本
- Android SDK（最低系统版本跟随当前 Flutter stable）
- Android Studio 或支持 Flutter 的编辑器
- iOS 构建需要 macOS、Xcode 和 CocoaPods

中国大陆网络可使用：

```sh
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

## 常用命令

```sh
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter run
flutter build apk --debug
```

iOS 工程只能在 macOS 上构建：

```sh
flutter build ios
```

## 启动流程与性能

Android 启动阶段使用深绿色背景与应用图标：Android 12 及以上通过系统 SplashScreen 主题配置，较早版本使用 `launch_background.xml`。Flutter 首帧显示同配色的品牌启动页，再并行初始化 SQLite 和后台任务调度器；随后并行恢复语言偏好与本地登录状态。启动页不设最短展示时间，也不等待服务端登录验证或同步请求。

Android 外部入口统一由轻量的 `LaunchActivity` 接收，先绘制带转圈及“正在启动…”的原生窗口，再调用 `FlutterLoader.ensureInitializationCompleteAsync` 加载 Flutter。转圈使用原生 AnimatedVectorDrawable，Android 7.1+ 在 RenderThread 上播放；引擎就绪后转交 `MainActivity`，完整保留 Intent 的数据、MIME、ClipData、参数及 URI 授权。启动窗口在 Flutter 显示后退出，不留在返回栈；加载中切到后台不会主动拉回应用。进程建立前的系统启动画面仍是静态图标，不人为添加展示时长。

`MainActivity` 等待 Flutter 首帧时继续显示相同加载层；`StartupFlutterFragment` 关闭默认的首帧前 Android 绘制阻塞，保留 surface 渲染。收到 `onFlutterUiDisplayed` 后移除原生加载层，由 Flutter 启动页接续。只把转圈放在 MainActivity 中不能覆盖此前的引擎初始化阶段。

数据库或后台调度初始化失败会显示重试入口；读取已保存的登录状态失败时也可重试，不会自动清除账号或缓存。应用锁初始化期间只显示启动页，解锁前仍遮挡账号内容。相关实现为 `lib/app_bootstrap.dart`、`lib/services/app_startup.dart` 和 `lib/ui/startup_page.dart`。

日常 debug 包包含调试开销，不适合用来衡量正式版启动速度。性能分析使用专用真机上的 `flutter run --profile`，发布体验使用 release 包；不要为测试启动速度卸载正在使用的客户端或清除数据。回归命令：

```sh
flutter test test/startup_test.dart test/app_lock_gate_test.dart test/account_switcher_page_test.dart test/localization_test.dart
```

## 应用版本信息

安装包版本由 `pubspec.yaml` 的 `version` 定义，构建时可用 Flutter 的
`--build-name` / `--build-number` 覆盖。“关于”通过
[package_info_plus](https://pub.dev/packages/package_info_plus) 读取实际安装包版本和构建号，
不使用源码常量代替。API2 协议版本仍由 `Api2Client.clientVersion` 定义并单独显示，
修改应用发布版本不应误改协议兼容规则。版本读取不请求 Gemsnote 服务端。

## 服务端要求

客户端要求 Gemsnote API2 v1.1.0。登录接口 `/api2/auth/login` 一次返回 token、用户资料和服务端版本，缓存记录该版本；旧 `/api` 与旧 Leanote 服务端不在支持范围内。

首次登录按 USN 分页下载笔记本、含正文笔记和标签，并在单个 SQLite 事务中替换该账号快照。默认在完整快照成功落库后保存登录状态。用户主动取消首次下载时保留已验证的登录状态，建立空缓存；取消已有账号的重新同步则保留原缓存。两者都会暂停自动同步，用户可手动同步或重新启用自动同步。下载失败仍按失败处理，不会提交残缺快照。

正文同步每页最多 10 篇，以 USN 连续翻页；单页正文请求采用独立的 5 分钟上限，普通 JSON 请求仍为 60 秒。超过上限会中止对应 HTTP 请求，而不关闭其他请求使用的客户端。包含大量内嵌图片或长正文的笔记仍可能需要较长传输时间，用户可以取消同步。界面区分连接失败、请求超时、正文下载超时；账号验证成功后同步失败，会明确说明失败发生在同步阶段。

## Android 大正文读取

部分 Android 设备的 SQLite `CursorWindow` 只有 2 MiB；即使使用 `LIMIT 1`，超过该大小的正文仍不能整行读出。笔记、共享正文、历史正文和新建笔记请求快照使用 `queryLargeValues`：普通字段正常读取，大文本按 256 KiB 的 UTF-8 字节块读取并完整还原。元数据与分块处于同一事务，避免读到并发修改前后的混合内容。无需清空缓存或迁移数据库结构。

本机回归：`flutter test test/data/large_note_storage_test.dart`。Android 原生回归仅在模拟器或专用测试设备上运行：`flutter test --no-uninstall integration_test/android_large_note_test.dart -d <测试设备ID>`。测试用例只创建并删除独立临时数据库，不连接真实服务端；但安装器仍使用日常应用的包名，数据库夹具隔离不代表安装过程不会影响应用数据。测试安装包运行完需重新构建并覆盖安装普通应用。

## 同步取消与账号隔离

完全同步、重新同步和登录后的下载进度窗支持“取消同步”。窗口等待请求与数据库收尾完成后关闭；取消不会撤销已经成功上传的内容，也不会把取消当成同步失败。重新同步只在完整快照下载完毕后提交替换事务，取消下载保留原缓存。

API2 的 HTTP 请求在当前任务作用域内使用可中断请求，覆盖响应头、正文和文件流。取消还会暂停当前账号的自动同步，避免前台定时器或系统后台任务立即重试。图片和附件队列也会中断进行中的 HTTP 下载。

切换账号、完成新账号登录和退出通过 SQLite 中的会话转换门闩及更新会话标识协调：停止旧同步、等待其释放写入租约，再激活新账号或删除登录状态。后台 isolate 在开始前和执行中检查会话标识；旧账号任务不能在切换后恢复。锁有过期和续租机制，不依赖修改数据库 schema。缓存身份仍为“服务器地址 + 用户 ID”。

错误码仅在 UI 层翻译，协议错误码保持不变。登录、同步、附件、共享、账号及系统操作错误遵循应用所选中文/英文；未知错误显示本地化提示，不展示包含 token 的网络地址或原生插件详情。

## 用户分组

账号页的“用户分组”入口提供在线分组列表、新建、重命名、删除和成员增删。自己创建的分组可管理，加入的他人分组仅查看；服务端再次校验创建者权限。成员输入支持用户名或邮箱，去除首尾空白，服务端统一解析用户 ID 并去重。

读取使用 `GET /api2/groups`，写操作使用 `/api2/member/group/*` 与 Bearer token，沿用现有表单字段；`addUser` 的 `email` 字段承载用户名或邮箱。该目录为服务端在线数据，不加入笔记离线 dirty 队列；失败保留输入并显示所选语言的错误，可重试。

验证：`flutter test test/user_groups_test.dart`；真实服务端专项使用 `scripts/test_api2_postgres.sh --plain-name 'real API2 groups accept usernames'`，只连接脚本建立的临时 PostgreSQL/API2 实例。

## 自动化验证

普通 Flutter 测试通过 `test/flutter_test_config.dart` 隔离宿主后台调度，
不会在 Linux/macOS 测试机器上启动或取消真实系统任务；后台调度专项测试使用
自己的记录实现检查调度参数。此配置不预先初始化 Widget 测试 binding，
保留纯 Dart 测试访问临时本地 HTTP 服务的能力。

SQLite FFI 的读取在真实事件循环中完成。相关界面用例使用
`test/support/wait_for_ui.dart` 等待实际显示状态并设定超时，避免依赖固定的
100 毫秒延迟而在 CI 高负载时偶发失败；功能断言不因等待方式改变而减少。

### 真实 API2 与 PostgreSQL 联调

运行 `bash mobile-app/scripts/test_api2_postgres.sh`（从项目根目录）。
脚本使用已有 PostgreSQL/Go/Flutter，在临时服务端副本和独立数据库中运行，
退出后停止临时进程，不安装软件或修改服务端仓库。
普通 Flutter 回归默认跳过这些需显式启用的联网测试。
设置 `API2_IOS_SIMULATOR=<已启动模拟器 ID>` 并通过 `with_xcode.sh` 运行同一脚本，
可执行真实 API2 登录、SQLite/钥匙串跨进程恢复及离线退出保护的两阶段设备测试。
使用独立测试数据，结束后恢复普通应用入口。
Android 设置 `API2_ANDROID_EMULATOR=emulator-5554` 并指定可用 `JAVA_HOME`，
无需 Xcode；只允许已启动的模拟器，使用同一两阶段测试和独立数据。

### Android 桌面小组件设备测试

`integration_test/android_home_widget_test.dart` 与
`scripts/test_android_home_widget.py` 配合验证真实原生通道、RemoteViews 列表和
PendingIntent。先在**专用、已退出账号的模拟器**安装普通 debug APK，启动一次应用，
并通过系统桌面的小组件选择器添加 Gemsnote 小组件到当前桌面。不要使用有重要数据的设备。

从 mobile-app 目录执行：

```sh
python3 scripts/test_android_home_widget.py emulator-5554
# 连接生产工作区、真实 SQLite 及离线保存：
python3 scripts/test_android_home_widget.py emulator-5554 --workspace
```

脚本允许通过 `ADB`、`FLUTTER_BIN` 覆盖工具路径。若终端 JAVA_HOME 失效，
请为本次命令指定 Android Studio 的 JDK。脚本拒绝真机、当前小组件账号非空及
当前桌面未添加小组件的情况；不登录、不访问服务器。它使用唯一虚拟账号和标题，
检查默认关闭、开启显示、点击笔记、关闭清空、切换账号、点击新建、切回原账号
以及退出清空，Dart 端核对每次真实回传的 account/action/noteId 和确认清理行为。
还验证过期账号/代次的发布被拒绝、开启偏好按账号保留。

日志和逐阶段桌面 XML 保存在输出的临时目录。使用 `--no-uninstall` 保留安装和
桌面绑定；成功或 Dart 断言失败时 finally 清除虚拟标题并关闭两个测试账号的显示。
若运行器被强制终止，不能保证 finally 执行。测试会留下两个关闭状态的虚拟偏好，
默认模式不写笔记数据库，工作区模式只写自己的临时数据库。
结束后安装普通入口恢复后续使用：

```sh
flutter build apk --debug --no-pub
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell am start -n com.github.gemsnote/.LaunchActivity
```

默认模式验证原生桌面行为，不代表 Flutter 工作区完整笔记导航、真实账号登录/同步、
系统回收或其他启动器均已验收。

`--workspace` 使用独立临时 SQLite 和生产 HomeWidgetController/WorkspacePage，
不读取用户笔记库，拒绝全部 HTTP 请求。宿主点击现有笔记后核对阅读页正文，
在阅读页仍打开时点击新建，确认返回工作区后才弹出笔记本选择；随后选择笔记本、
编辑标题/正文、保存，桌面点击新标题并核对新正文，最后重开 SQLite 验证持久化。
此模式不处理分享收件箱，结束时清理自己的数据库和小组件标题。

Android 小组件 Intent 的 URI 用于区分 PendingIntent，导航由原生通道和工作区处理。
Activity 设置 `flutter_deeplinking_enabled=false`，防止默认 Flutter 深链处理器
把该 URI 再次推为命名路由，触发找不到路由异常。配置依据见
[Flutter 默认深链处理说明](https://docs.flutter.dev/release/breaking-changes/deep-links-flag-change)。

生命周期检查要区分后台进程终止与用户强制停止：Android 15 的强制停止会取消
PendingIntent 并禁用小组件，直到用户重新启动应用。因此 `am force-stop` 后的小组件
点击不能作为普通进程回收的等价验证；见
[Android 15 停止状态变更](https://developer.android.com/about/versions/15/behavior-changes-all?hl=en)。
已在专用模拟器确认普通应用后台进程终止后，单次标题点击能以新进程进入登录页。

### CI

独立 mobile-app 仓库的 `.github/workflows/ci.yml` 在分支 push、PR 和手动触发时执行。
固定 Flutter 3.47.5（本地验证使用的版本），只执行检查和测试，不构建安装包：

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

只有推送无 `v` 的正式版本 tag 才由 `release.yml` 构建并发布 Android Release APK/AAB。
tag 必须匹配 `pubspec.yaml` 的版本，发布前复用上述 CI 测试。
签名凭据和本地发布方式见 [发布指南](RELEASE.md)。

测试工作流只授予仓库内容读取权限，不使用部署或签名凭据，也不自动发布。
新推送会取消同一分支尚未完成的旧测试任务。此处 CI 不使用签名凭据；
发布工作流仅 publish job 有仓库写权限，不自动上传到应用商店。
工作流沿用上文镜像，确保 Pub 下载源与 `pubspec.lock` 中记录的地址一致；
切换源时应统一更新锁文件并重新验证，不能忽略 `--enforce-lockfile` 失败。
升级 Flutter 时需同时核对工作流固定版本、Dart SDK 约束和 Android 工具链。

### 原生设备专项

原生集成测试仅使用模拟器或专用测试设备，不直接在保存日常账号数据的手机上运行。当前 Flutter 的 `flutter test integration_test/...` 默认在结束时卸载测试应用；测试包与普通应用包名相同，卸载会删除登录凭据和本地缓存。以下命令显式加上 `--no-uninstall`，阻止测试结束后的自动卸载；它不能代替设备隔离，也不能保护因签名冲突等原因发生的卸载重装。

`integration_test/native_smoke_test.dart` 使用真实设备插件，检查临时 SQLite
数据库关闭重开后正文及格式保留、安全存储读取，以及 WebView 中富文本加粗和撤销。
iOS 还检查真实通道能否访问 App Group 收件箱，不认领或删除现有分享。
测试使用独立临时数据库和随机测试密钥，并在结束时清理；不连接服务端，
不能作为真实 API2 登录或同步验收证据。

```sh
flutter test --no-pub --no-uninstall integration_test/native_smoke_test.dart -d emulator-5554
```

替换设备 ID 可用于其他已连接的测试设备。iOS 使用下节的 Xcode 环境脚本：

```sh
DEVELOPER_DIR=/Volumes/LC128G/Applications/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh ~/opt/flutter/bin/flutter test --no-pub --no-uninstall \
  integration_test/native_smoke_test.dart -d <iOS模拟器ID>
```

测试会安装测试入口应用；结束后如需继续手工使用，重新构建并安装正常的
`lib/main.dart` debug APK 或 iOS 模拟器应用。2026-10-20 Android 35
通过 2 项，iOS 26.3 通过 3 项。WebView 测试在加载完成后等待界面渲染，
确保编辑发生在已挂载的原生视图上；离屏视图的 WebKit 撤销行为不能作为界面验收。
普通 `flutter test` 仍只运行 `test/`，不自动启动模拟器。

Android 可一次运行原生存储/WebView 和应用锁导航检查（从 mobile-app 目录执行）：

```sh
flutter test --no-pub --no-uninstall integration_test/android_runtime_test.dart \
  -d emulator-5554 --reporter expanded
```

此入口复用应用锁页面场景，在设备上核对已打开的编辑页和弹窗被锁屏遮住、取消解锁
继续隐藏、解锁后保留草稿及导航，以及读取锁设置失败后的重试。认证结果由测试提供，
不会配置设备 PIN 或触发生物识别系统弹窗；不作为真实认证弹窗、系统锁屏或最近任务
截图的验收证据。`--no-uninstall` 阻止测试结束时自动卸载，测试用例只清理自己的夹具；仍须遵守上述测试设备隔离要求。
结束后仍需重新构建并覆盖安装普通入口，不能把测试入口当作日常客户端使用。

### iOS 原生权限文案

相机权限用途说明位于 `ios/Runner/{en,zh-Hans,zh-Hant}.lproj/InfoPlist.strings`，
通过 Xcode 的本地化资源组随 Runner 打包；Info.plist 中英文说明保留为回退。
这些说明由 iOS 为该应用选择的语言决定，不能靠 Flutter 的运行时语言偏好
动态改写系统权限弹窗。Flutter 界面、分享扩展和相机错误提示仍使用既有语言设置。
添加新权限用途说明时，应同时维护本地化资源和英文回退。

2026-10-20 已检查构建产物中的三种文案，以及简体/繁体区域选择和英文回退；
此检查不代替真机授权弹窗与相机功能验收。

### 本地 iOS 模拟器编译检查

2026-10-20 后续复查：iOS 26.3 模拟器运行时和设备已经安装，CocoaPods
1.17.0 可用。执行 `flutter pub get --offline` 刷新插件配置后，工程已生成
Podfile 和配置引用，`pod install` 成功，`open_filex` 通过 CocoaPods 回退集成。

当前 hooks_runner 会过滤 `DEVELOPER_DIR`，仅在命令前指定该变量不足以
让原生构建钩子找到 SDK。系统 `xcode-select` 仍指向 CommandLineTools，
可使用项目脚本为单次命令配置 xcrun，无需修改全局设置：

```sh
DEVELOPER_DIR=/Volumes/LC128G/Applications/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh ~/opt/flutter/bin/flutter pub get
DEVELOPER_DIR=/Volumes/LC128G/Applications/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh ~/opt/flutter/bin/flutter build ios --simulator --debug
```

模拟器分享验收使用默认签名构建，不加 `--no-codesign`；无签名构建可用于编译检查，
但本机实测无法访问 App Group，分享保存会明确报错。

`pub get` 也必须使用同一 Xcode 环境，否则可能生成空的 Swift Package
插件列表，而后续 `--no-pub` 构建只报告插件模块缺失。不要手工编辑
`ios/Flutter/ephemeral` 下的生成文件。当前锁文件使用 `https://pub.dev`，
依赖准备应使用相同来源；若 shell 设置了其他 `PUB_HOSTED_URL`，可在单次命令前
加 `env -u PUB_HOSTED_URL`。离线执行还需要该来源的完整本地缓存。

脚本通过临时 PATH 入口保留 Xcode 选择，并在命令结束后清理入口。
若希望普通命令也默认使用完整 Xcode，可在本机终端执行：

```sh
sudo xcode-select --switch /Volumes/LC128G/Applications/Xcode.app/Contents/Developer
env -u DEVELOPER_DIR xcode-select -p
env -u DEVELOPER_DIR xcrun --sdk iphonesimulator --show-sdk-path
```

切换需要管理员密码，本轮自动执行的 `sudo -n` 未获认证，未改变系统设置。
验证时必须移除终端已有的 `DEVELOPER_DIR`，否则会误认为系统级路径已切换。
外接盘需要保持连接。2026-10-20 实测 Flutter doctor 的 Xcode 检查通过、
UIKit Swift 代码在 iOS 模拟器 SDK 下类型检查通过，iPhone 12 mini /
iOS 26.3 模拟器约 29 秒启动成功。完整应用构建曾报
`Module 'file_picker_darwin' not found`，原因是生成的 Swift Package
依赖列表为空；在上述环境执行 `pub get` 后，完整 Debug 模拟器构建
通过（223.1 秒），安装及启动成功，截图确认中文登录页。
首次安装可能等待 macOS 对模拟器访问 Documents 的系统授权；本机此次等待后完成，
不能把静默安装当作应用崩溃。系统分享、相机及完整业务流程仍需后续验收。

分享存储可独立验证（使用上述 Xcode 环境）：

```sh
xcrun swiftc ios/Shared/SharedTextStore.swift ios/SharedTests/SharedTextStoreTests.swift -o /private/tmp/gemsnote-share-tests
/private/tmp/gemsnote-share-tests
```

该测试不代替系统分享面板验收。扩展每批最多保存 8 项、总资源 32 MiB，
使用 App Group 原件和跨进程锁；宿主应用必须正确配置相同 App Group 权限。

普通 push/PR 不再构建模拟器包。可在 macOS 上使用相同 Flutter 版本手动执行：

```sh
flutter pub get --enforce-lockfile
flutter build ios --simulator --debug --no-pub
ditto -c -k --keepParent build/ios/iphonesimulator/Runner.app build/gemsnote-ios-simulator.zip
```

工程使用 Flutter 的 Swift Package Manager 集成；不要复制本地生成的
`ios/Flutter/ephemeral` 或插件注册文件到仓库。Flutter 构建负责生成这些文件；
如插件需要 CocoaPods 回退，macOS 环境还需提供 CocoaPods。

解开 `build/gemsnote-ios-simulator.zip` 可得到 `Runner.app`。
模拟器包不是 IPA，不能安装到 iPhone 或上传 App Store/TestFlight；不需要提供开发者证书。
产物架构以实际 Mac 和 Xcode 构建结果为准，使用兼容架构的 Mac/iOS 模拟器测试。

本地执行这些命令需要 macOS/Xcode，见 [Flutter iOS 构建说明](https://docs.flutter.dev/deployment/ios)。
Linux 上只能检查工作流与工程文件，不能据此宣称 iOS 编译或安装验证通过；
iOS 签名发布流程仍待实现，不把模拟器包充作 Release 安装包。

## 应用图标

高分辨率源图为 `assets/branding/gemsnote.png`，来自项目提供的透明背景 Gemsnote 图标。
该目录仅用于构建维护，不作为 Flutter 运行时资源打包；页面仍使用 `assets/images/gemsnote_s.png`。
安装 ImageMagick（Ubuntu/Debian：`sudo apt install imagemagick`；macOS：`brew install imagemagick`）后运行：

```sh
bash scripts/generate_icons.sh --help
bash scripts/generate_icons.sh
flutter test test/launcher_icons_test.dart
```

脚本可从任意工作目录调用，支持 ImageMagick 6 的 `convert` 和 7 的 `magick`，
不下载外部资源，只覆盖当前 Flutter Android/iOS 工程的图标 PNG。
生成物提交到 Git，因此普通构建无需安装 ImageMagick。

Android 提供五档密度的传统图标和前景图，以及 API 26+ 自适应图标 XML。
前景置于 108dp 画布的中央 46dp 方形内，保证完整主体位于 66dp 安全圆内，
背景使用 `#193b35`；参见 [Android 自适应图标规范](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。
iOS 保留现有 asset catalog 的全部尺寸及 1024px 图标，输出无透明通道 RGB PNG，
不预先裁圆角；参见 [Apple AppIcon 资源目录说明](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。
当前未提供 Android 主题单色层或新的 iOS 分层外观。
更新图标后需要重新构建/安装应用，不会通过 Flutter 热重载替换桌面图标；
iOS 编译仍需 macOS/Xcode，桌面遮罩及安装后的显示需真机验证。

## 同步模式

- 立即同步：先上传本地 dirty 笔记，再从上次账号 USN 拉取增量。
- 完全同步（合并）：同样先上传，然后从 USN 0 下载所有类型，使用同一个事务合并流程；用于补回遗漏的旧记录，不清空本地数据。
- 重新同步：确认后不上传本地修改，下载成功才原子替换账号快照；下载失败保留原缓存。

完全同步由 `SyncCoordinator.synchronizeFull` 实现，不新增或修改 API2 接口。
与增量同步使用相同的固定检查点、分页和 dirty 防覆盖逻辑；服务端 USN 倒退仍拒绝合并。
未出现在快照中的本地记录不会自动删除或重传，明确的远程删除标记仍生效。
正文及资源冲突支持保留完整本地副本（详见下节）。完全同步替换命中的笔记行时，
其关联文件缓存沿用既有合并清理规则；不保证所有文件缓存保留。

### 正文冲突副本

`getConflictSnapshot` 在正文读取前后核对远程 USN 和完整文件清单；字段缺失或 null
不能证明没有资源。`resolveNoteConflict` 在事务内再次核对完整本地快照，避免覆盖在途编辑。
资源副本读取当前缓存、历史恢复缓存和待上传原件，校验正文引用与资源指纹后，在同一事务
创建独立 NoteId、正文和持久上传任务。任何必需原件缺失、资源变化或正文并发编辑都会拒绝
旧快照并保留原 dirty 笔记，不生成只有失效链接的不完整副本。

本地副本保留原始内容、标题（追加“本地冲突副本”）、标签、笔记本及星标，
新 ID、USN 0、dirty/new 标志与原笔记采用服务端版本在同一事务落库。
之后用既有 API2 新建笔记接口上传副本；失败保留相同 ID 待重试，不再为原笔记创建副本。
新副本创建/修改时间表示副本生成时间，不改写服务端原笔记的时间。
正文及格式相同时的元数据冲突仍不创建副本。远端永久删除时只从本地缓存和待上传任务恢复
原件；资源齐全才创建恢复副本，缺失时保留原待同步记录并提示用户处理。

## Markdown 阅读

Markdown 阅读使用 [flutter_markdown_plus](https://pub.dev/packages/flutter_markdown_plus)
原生组件，并保留可复制的原文模式。个人笔记图片由账号隔离的缓存组件处理；
未缓存时由用户手动点击、经 API2 校验后下载，不启用渲染器默认的网络/本地文件加载。
共享和历史图片使用各自按账号隔离的受控缓存；未缓存时只允许用户明确下载合法 API2 资源，不使用正文 URL 自动联网。编辑预览只读取当前账号、当前笔记的已有缓存。Markdown 链接先展示地址，允许复制或确认外部打开 HTTP/HTTPS 地址；不自动导航。
此实现不支持 Markdown 中内嵌 HTML 的浏览器渲染。

## 富文本阅读

个人笔记默认与共享、历史一样使用 `SafeHtmlNoteBody` 原生安全预览，不使用 WebView
自动读取正文资源。保留基本排版、原文查看/复制/导出，不执行脚本、CSS、嵌入页面或链接。
复杂布局和表格样式降级，不写回转换结果；HTML 已提供基础可视化编辑，复杂 HTML 和图片仍使用原文编辑。
个人笔记额外接入现有账号隔离图片缓存：前 100 张 `img` 图片按原文顺序穿插在文字之间，
各自独占一行且宽度不超过正文，不还原 CSS 浮动或文字环绕。缓存缺失时仅对合法同源 API2 文件引用提供手动下载。
图片集合跳过脚本、iframe 等被省略内容，不使用 `srcset`、CSS 图片或外部资源自动加载。
返回文件页后更新缓存显示；编辑预览可读取已有图片缓存，但不传入下载能力。共享和历史页面使用独立缓存、版本及权限校验，不能读取个人笔记缓存冒充对应资源。

## 编辑撤销与重做

`NoteEditorPage` 为标题和正文分别持有 Flutter `UndoHistoryController`，工具栏
根据最后获得焦点的输入框选择对应历史；无可用历史及离开保存期间禁用按钮。
初始 `TextEditingValue` 必须具有有效 selection，否则首个修改前的原文不会入栈。
正文输入框通过 `IndexedStack` 在预览时保留状态，避免销毁输入框导致历史丢失。

文本历史合并、输入法和键盘快捷键沿用 Flutter 内建行为；Markdown 格式工具也
修改同一控制器，撤销/重做继续触发既有自动保存，保存失败保留文本并显示重试。
历史只存在于当前编辑页内存，不写数据库，不跨笔记或跨会话保留，不替代服务端
历史版本。Android/iOS 输入法及原生撤销手势仍需真机验收。

## 原文导入

Markdown 单文件与 ZIP 内的 Markdown 均解析 Hugo YAML（`---`）、TOML（`+++`）、JSON front matter：
标题、`date`、`lastmod`、`tags` 写入笔记元数据，完整 front matter 从正文移除。
没有 front matter 的文件使用文件名、当前时间和空标签；有元数据时标题缺失则留空，
只提供一个日期则用于创建与修改时间，两项日期都缺失或日期无效则拒绝导入。
无时区的日期统一按 UTC 解释。ZIP 不创建文件名对应的外层笔记本，根目录文件放入当前笔记本，
目录逐层成为子笔记本。ZIP 最大 32 MiB，内部 Markdown 单篇最大 4 MiB、合计 64 MiB；
最多 2000 篇、1000 个笔记本、20 层目录。先校验完整 ZIP，再通过一个 SQLite 事务创建目录与笔记。
删除笔记本的确认框提供默认不勾选的“同时删除笔记”选项，笔记移入回收站；有子笔记本时需先处理。

笔记本右侧的三点菜单可通过系统文件选择器导入 UTF-8 Markdown、TXT、HTML，以及 RTF/DOCX，单文件
最多 32 MiB；同时检查文件扩展名、声明大小和实际流式字节数。文本文件拒绝无效 UTF-8 和
含 NUL 的内容，去除 UTF-8 BOM；RTF/DOCX 按文档格式单独解析。TXT 按 Markdown 保存，HTML 保持原文，
预览沿用安全渲染，不执行脚本、不自动读取关联资源。

导入目标为打开三点菜单的笔记本，对话框显示目标名称，不依赖当前选中的笔记本。
选择文件不写库，确认后将标题、正文与新建/dirty 标记一次写入当前账号 SQLite，
后续沿用现有上传流程，不新增 API2 接口。取消不创建笔记；失败保留对话框可重试。
原文模式不包含附件或历史；`.gemsnote` 归档另行保留正文、支持的元数据和二进制资源，
导入后进入既有资源上传队列，不导入服务器历史。系统分享接收使用独立入口。
Android DocumentsUI 不认识 `.gemsnote` 扩展名对应的 MIME，使用 custom 过滤会让
已导出的归档变灰；Android 选择器现允许浏览任意文件，选择后仍严格验证扩展名、
大小和归档内容。其他平台保留扩展名过滤。

## 文档导入与笔记本导出

`NoteExporter` 调用已锁定依赖版本的 `FilePicker.saveFile`，使用返回的 URI 判断
是否保存，取消返回 null；不把 Android content URI 当作本地路径写文件。
测试可注入保存回调验证字节、文件名、取消和失败行为。Markdown 笔记导出为 Hugo Markdown，包含 `title/date/lastmod/tags/categories`，正文原样保留；
富文本笔记导出为 RTF，保留常见文字格式、列表、表格和链接。ZIP 中也使用各自格式。
日期使用笔记时间转 UTC，缺失值为 `null`，不以导出时间替代。笔记本三点菜单可导出 ZIP，
包含子笔记本及空目录，不含回收站，重名文件自动加序号。使用当前账户本地 SQLite 缓存，离线可用；
ZIP 转换与打包在 isolate 中执行，上限 128 MiB 正文、10000 篇笔记、3000 个笔记本及 100 层目录。
导出不执行 HTML，也不下载图片和附件；RTF 中图片保留说明及原链接，复杂富文本样式可能简化。
RTF/DOCX 导入通过 `rich_document.dart` 在 isolate 中转换为富文本 HTML，随后按现有确认流程写入 SQLite 并标记 dirty。
DOCX 只解压必需的 XML，检查解压大小、CRC、重复路径、符号链接和加密标志，拒绝 DTD/外部实体；不执行宏、不抓取外部资源。
输入和转换后内容最多 32 MiB；单个 DOCX XML 最大 4 MiB，总 XML 最大 16 MiB。复杂排版、内嵌图片/对象不能无损转换，确认前提示并保留占位文字。
`.gemsnote` 带资源归档仍保留原始正文、格式、元数据和资源，不经过 Markdown 转换。
iOS 保存对话框只能在 macOS/iOS 环境完成构建和真机验收。

### Android 系统文件选择器验证

在英文系统、已启动且已有普通 Gemsnote APK 的一次性 Android 模拟器上运行：

```sh
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  python3 mobile-app/scripts/test_android_file_picker.py emulator-5554
```

脚本运行生产 NoteExporter/NoteImporter，使用真实 DocumentsUI 保存到 Downloads，
再选择同一文件。覆盖 Markdown、富文本 RTF、含二进制附件的 `.gemsnote` 往返，
不支持扩展名的拒绝和保存/导入取消；宿主额外核对 Hugo 元数据、Markdown 正文、RTF 控制字和归档二进制、
取消后没有产物。只清理本次唯一命名文件，失败保留日志和文件便于诊断。
不登录、不访问网络、不写账号数据库，不代表工作区导入落库、云文件 provider 或 iOS 验收。
运行后需重新构建并覆盖安装普通 APK，避免设备留在集成测试入口。

### iOS 系统文件选择器验证

```sh
DEVELOPER_DIR=/Volumes/LC128G/Applications/Xcode.app/Contents/Developer \
  bash mobile-app/scripts/with_xcode.sh \
  bash mobile-app/scripts/test_ios_file_picker.sh <已启动的模拟器 UUID>
```

脚本构建测试专用 Flutter 入口（仍调用生产 NoteExporter/NoteImporter），并创建独立
PickerFiles 测试应用作为“我的 iPhone”中的本地文件夹。通过 XCUITest 操作真实文件面板，
逐项保存并导入 Markdown、富文本 RTF、含二进制资源的 `.gemsnote`，验证正文、格式、元数据和
附件原件；保存/导入取消也必须返回。按钮支持中英文，iOS 26 导出面板无取消按钮时通过
下拉关闭手势验证取消回调。宿主读取三份导出文件再次核对正文和二进制字节，
成功后仅删除本轮唯一命名产物，失败保留证据。项目文件及 DerivedData 均在临时目录。

测试不访问账号、服务器或正常笔记数据库。iPhone 12 mini / iOS 26.3 模拟器已通过，
不能外推为 iCloud、第三方文件 provider、iPad、真机或工作区落库验证。
测试后须使用 `--target lib/main.dart` 重新构建普通模拟器应用并通过 `simctl install`
覆盖安装；不要把测试入口作为正常应用或发布产物。

图片预览通过 `ImageExporter` 复用系统文件保存能力和文件名清理逻辑，只保存已读取的
图片字节，不再请求服务器。输出扩展名和 MIME 由 PNG/JPEG/GIF/WebP 文件头确定，
不信任服务端文件名或类型；仍限制每张最多 8 MiB。该检查只识别格式，图片解码验证
由读取图片的仓储层负责。导出到系统文件后不再受账号缓存清理控制，用户自行管理。

## 附件保存

普通附件通过 `/api2/note/getNote` 校验个人笔记归属与文件成员后，调用
`/api2/file/getAttach`，不使用正文 URL。该接口错误也可能返回 HTTP 200，
因此必须同时检查 `Content-Disposition: attachment`，不能把 JSON/登录页当附件保存。
下载不跟随重定向，响应头限时 30 秒、响应体总限时 60 秒，大小上限 32 MiB；
完整下载到内存后才打开系统保存窗口，空附件允许保存。文件名来自已校验的列表并清理路径字符，
忽略响应头文件名；原始字节不执行、不自动打开。下载后通过文件快照代号校验写入
现有 `note_files` 表，图片和附件共用 64 MiB 全账号字节限额，无需变更 schema。
取消保存仍保留缓存；显式离线保存不调用 API，空字节与未缓存的 NULL 区分。
刷新列表、权限撤销、删除与重新同步清理沿用图片策略，普通网络失败保留缓存但不自动回退。

## 测试原则

`FileCacheBatch` 是当前文件页持有的一次性并发队列，最多 3 个 worker，按文件类型和 ID 去重，
分别调用仓储的 `noteImage` / `noteAttachment`；下载仍会重新检查服务端归属及文件成员关系。
单个失败不丢弃其他下载结果，结果返回失败文件以供显式重试。取消仅停止调度新项目，
不强行中断已经开始的 HTTP 请求；页面销毁后不更新 UI，旧快照写入由既有仓储层拒绝。
运行时禁用列表刷新、离线切换和单文件打开/保存，避免文件列表快照被当前页面并发替换。
不会打开系统保存对话框，也不宣称超出 64 MiB 淘汰预算的文件仍全部缓存；
不提供跨页面、重启恢复或系统后台下载保证。

标签页面与编辑候选复用 `tagChoices` 的稳定排序/过滤。数据来自当前账号 SQLite
笔记的引用计数，不从标签同步表推断有哪些标签，不发起网络请求；每次打开页面/对话框
重新读取。标签页空查询显示前 10 个，非空查询搜索全部；编辑候选排除已选标签，
最多 20 个并可继续输入缩小范围。小屏使用有高度限制、可滚动的候选标签块，
不照搬桌面浮动列表。已有标签全部清空的服务端合同限制不变。

系统分享使用锁定的 `share_plus` 版本及 `SharePlus.instance.share(ShareParams(...))`，
仅传个人笔记标题、正文纯文本与当前菜单按钮位置（iPad popover 必需），不共享附件或凭据。
文本 UTF-8 上限 256 KiB，避免 Android 大文本 Intent 超限；不截断，超限改用导出原文。
原生结果只是面板交互结果，不是发送成功回执，因此不显示“分享成功”。测试注入分享回调，
验证载荷、取消/未知结果、失败及防重复操作；实际 Android/iOS 分享面板需真机验收。

`NotebookTargetPicker` 是笔记与笔记本移动的共用目标选择组件，复用 `NotebookTree`
的展示树；搜索只过滤显示并保留祖先，不重写层级或 ID。`canSelect` 控制合法目标，
笔记本移动继续使用 `canMoveNotebook` 检查原始父级链，不能只依赖展示树防止循环。
展开操作不触发选择，搜索不更改展开状态；无选中目标时不能提交。

- API 客户端测试必须检查 HTTP 方法、路径和 JSON 请求体
- SQLite 测试使用内存数据库，不依赖真实用户数据
- 同步测试需要覆盖分页、超时、原子提交、ID 映射和账号隔离
- 提交前至少运行 `flutter analyze` 和 `flutter test`

## 正文图片插入

Markdown 与 HTML 原文编辑器提供在线图片插入。图片选择及上传继续使用
`NoteImagePicker` / API2 `pasteImage`；仓库层复用资源上传互斥，先上传当前笔记，
不上传其他 dirty 笔记，不自动解决正文冲突。工作区入口等待账号资源缓存停止。
上传接口本身不会建立笔记图片关联，也不推进账号同步游标。

返回有效图片引用后，编辑器保留原文，将图片语法写入正文并立即本地保存。
Markdown 在选区末尾插入；HTML 始终在文末追加，避免在标签或属性内部插入。
正文随后走现有 dirty 同步流程，服务端保存正文时解析 API2 图片引用并建立关联；
上传图片后不提前把资源标为当前笔记的缓存成员。阅读页同步后可按既有流程手动下载。
插入后保存失败保留内存中的引用和错误横幅，重试只保存正文，不再次上传图片。
上传结果不确定时关闭本次提交入口，不自动重试；未关联图片清理尚未实现。

回归覆盖编辑器选区、取消、保存失败、上传超时、密码清理、互斥及新笔记先上传流程：

```sh
flutter test test/editor_image_test.dart test/data/note_image_repository_test.dart test/note_image_upload_test.dart
```

## Android 分享接收

依据 [Android 分享接收文档](https://developer.android.com/training/sharing/receive)，
Manifest 注册 `ACTION_SEND` / `ACTION_SEND_MULTIPLE`，Activity 使用 `singleTask`，
冷启动和 `onNewIntent` 统一处理文本、图片、文件与多项分享。文本单项最多
UTF-8 256 KiB，二进制单文件最多 32 MiB；每批和持久收件箱最多 8 项。
文件只读取来源明确授权的 `content://` URI，原件写入应用私有目录；批次中任一项失败时整批不入队。

`gemsnote/shared_text` MethodChannel 提供 peek、claim、acknowledge 和 changed 通知。
Flutter 在工作区启动/恢复前台时读取队列，事件仅更新工具栏标记，不打断正在编辑的笔记。
没有登录时原生继续保留队列；稍后处理不消费。用户选择账号和笔记本并确认后，
先 claim 绑定服务器/用户缓存键，再在 SQLite 事务中验证目标笔记本、创建 dirty/new
Markdown 笔记。重复 ID 返回原笔记，不覆盖后续编辑；最后 acknowledge 清除原生条目。
确认忽略只清除队列，不写笔记。正文始终作为文本处理，不访问分享中的 URL。
Android 图片、文件和多项接收已经实现；完整安全边界和 JVM 验证见
[ANDROID_SHARING.md](ANDROID_SHARING.md)。iOS 已实现单项文本和 HTTP(S) 网页 Share Extension，
图片、文件和多项接收仍待迁移，见 [IOS_SHARING.md](IOS_SHARING.md)。

回归命令：

```sh
flutter test test/shared_text_inbox_test.dart test/shared_text_dialog_test.dart test/data/shared_text_import_test.dart
flutter build apk --debug --no-pub
```

设备验收应覆盖：退出应用后的浏览器文本分享、编辑中再次分享、多条队列、登录前分享、
稍后处理重启、取消/确认忽略、错误账号、缺少笔记本，以及本地保存/队列清理失败重试。
纯 Dart 测试不替代 Android 原生 Intent 和跨应用分享面板验收。

## 默认编辑器偏好

账号菜单中的默认编辑器选择只影响本机新建笔记；未设置时为富文本。
新建菜单每次从数据库读取，第一项使用默认格式，第二项允许临时选择另一种格式。
文件导入、分享导入和已有笔记继续使用各自的格式，不因偏好变化转换正文。

SQLite v6 增加 `account_preferences`，按账号缓存键（服务器 + 用户 ID）隔离。
这是本地偏好表，不关联 USN 或 dirty 状态；刻意不使用账号表的级联外键，
因为重新同步使用账号快照 REPLACE，而偏好需要保留。写入时事务内验证账号存在。
v5 升级只建表，保留已有正文、未上传标记和同步游标。

```sh
flutter test test/data/default_editor_test.dart test/default_editor_test.dart
```

## 附件系统分享

### Android 实际接收验证

使用已有 SDK 和一次性、英文系统的已启动模拟器：

```sh
fixture_apk="$(bash mobile-app/scripts/build_android_share_fixture.sh)"
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  python3 mobile-app/scripts/test_android_outbound_share.py emulator-5554 "$fixture_apk"
```

测试调用生产 NoteSharer/AttachmentSharer，通过真实 Android 分享面板选择
`Gemsnote test receiver`，不发送给外部服务。接收 Activity 无存储和网络权限，
实际使用临时 URI 授权读取附件，并将结果写在自己的私有目录。
宿主核对 Markdown/HTML 标题和完整原文、分享 MIME、清理后的文件名、
`content://` 读取授权、二进制及空附件字节；取消后必须仍只有四条接收记录。
面板目标折叠时脚本上滑展开。成功后卸载临时夹具并清理自己的 UI 快照，
保留宿主接收证据；失败保留夹具用于诊断。

Android 35 模拟器已通过；这不代表邮件/聊天软件的交付结果，也不代表阅读页、
附件下载到分享的完整流程或 iOS 分享验收。运行后需构建并覆盖安装普通
`lib/main.dart` APK，避免设备停留在集成测试入口。

### iOS 实际接收验证

```sh
DEVELOPER_DIR=/Volumes/LC128G/Applications/Xcode.app/Contents/Developer \
  bash mobile-app/scripts/with_xcode.sh \
  bash mobile-app/scripts/test_ios_outbound_share.sh <已启动的模拟器 UUID>
```

脚本构建只调用生产 NoteSharer/AttachmentSharer 的测试界面，以及独立 ReceiverHost
应用和 ShareReceiver 测试扩展。系统面板使用所属应用名称 `ReceiverHost` 显示目标。
扩展读取真实 NSItemProvider 的文本或临时文件，用 UI 中的 JSON 回执供 XCUITest
精确核对原文、文件名、二进制及空附件；不会把选择目标或插件返回当作交付证据。
接收端没有网络调用，不访问真实账号；这不代表邮件/聊天软件或 iPad 的验收。
紧凑面板的取消通过点击背景验证，同时检查面板消失和调用返回。
iPhone 12 mini / iOS 26.3 实际通过；成功后卸载接收应用。
日志、生成工程和 DerivedData 在临时目录。结束后必须构建 `--target lib/main.dart`
并覆盖安装普通应用，不能发布测试入口。

### 业务调用与临时文件

个人笔记文件页的“分享附件”通过现有 share_plus 调用系统分享菜单。
NoteFilesPage 先调用 noteAttachment，遵守联网校验与显式 cachedOnly 模式，
不在联网失败后自动回退缓存；下载结束后检查页面仍在，再取当前页面位置用于 iPad 弹窗。
附件下载和系统分享期间与保存、刷新、上传、批量缓存互斥。
AttachmentSharer 再次限制 32 MiB（允许空文件），清理文件名并保留短扩展名，
以 XFile.fromData 和 fileNameOverrides 传递原始字节，仅按已知扩展名提供 MIME 提示。
不添加账号信息、凭据或 URL，不修改笔记或同步状态，也不把选择目标视为成功送达。

share_plus 会将内存文件写入原生临时缓存供目标应用读取；这些副本可能在分享结束后保留，
生命周期由插件及系统管理，不属于 SQLite 的 64 MiB 缓存配额，不能在分享返回时立即删除。
本实现不增加存储目录权限或依赖，不是直接启动默认文件查看器。
测试覆盖字节及文件名、大小边界、分享结果、在线/离线选择、失败重试、重复操作与离开页面。
原生目标应用能否接收不同文件类型及 iPad 弹窗位置仍需 Android/iOS 真机验收。

## 笔记排序持久化

支持创建时间、修改时间和标题的升序/降序，菜单跟随中英文语言设置。创建时间按 `CreatedTime` 排序，不使用修改时间替代；时间比较识别时区，无效或缺失时间始终排在最后，相同值按笔记 ID 稳定排序。

schema v23 扩展 `account_note_sort` 的 CHECK 约束，允许 `createdAscending` 和 `createdDescending`。升级在数据库事务内重建此偏好表并复制旧设置，不重建账号或笔记表、不清空缓存与未上传修改；应用发布版本号不变。

schema v7 新增 account_note_sort，按规范化服务器地址和用户 ID 保存 NoteSort 名称，
缺省为修改时间降序。独立于默认编辑器表，CHECK 限制合法枚举，写入事务确认账号存在。
与其他本地偏好一致，不设置随账号快照 REPLACE 级联删除的外键；退出及重新同步保留，
不进入 dirty 数据或同步游标。v6 升级只创建偏好表，不迁移或重写笔记内容。

工作区启动异步读取偏好，读取期间禁用排序菜单；失败仍可阅读列表，并显示重试入口。
保存期间禁止重复选择，只有数据库写入成功后应用排序；失败保留旧顺序，重试保存原选择。
Widget 测试覆盖完整工作区重建、加载失败重试与保存失败重试，数据库测试覆盖 v6 升级、
未同步正文保留、账号隔离、重新打开、快照替换及默认编辑器互不覆盖。

## 离线资源缓存管理

账号菜单的 FileCacheDialog 通过 repository 读取当前账号 note_files 中非 NULL bytes 的数量
及 length(bytes) 总和，空附件算一个已缓存文件。该缓存管理功能无需额外升级表结构。
清理仅更新当前账号文件行的 bytes=NULL、cached_at=0，并轮换全部行的 generation，
包含尚未完成下载的文件行，防止旧请求回写；保留文件元数据、笔记、dirty 和 USN。

工作区打开对话框后先取消并等待 AccountFileCache，再读用量。窗口打开期间不启动
自动同步或新的账号资源队列；清理需二次确认，处理期间禁用重复点击和关闭。
本操作离线可用，不请求服务端，不清理其他账号、导出或系统分享的临时副本。
SQLite 可复用空闲页，但不执行 VACUUM，不用缓存字节数承诺实际磁盘释放量。
测试覆盖账号隔离、空文件统计、dirty 正文保留、旧下载失效、新下载重新缓存、
资源队列等待、取消、失败重试及重复点击。

## Markdown 链接外部打开

MarkdownNoteBody 的 onTapLink 只打开 NoteLinkDialog；渲染与第一次点击不调用 URL launcher。
确认窗显示完整地址及解析后的 host。NoteLinkOpener 再次校验完整 HTTP/HTTPS URI、端口、
无内嵌凭据、无空白/控制字符/反斜杠/方向控制字符以及 8192 字符上限，
再以 url_launcher 的 LaunchMode.externalApplication 交给系统关联应用。
不调用 canLaunchUrl、不额外申请应用列表查询权限，不建立应用内浏览器，
不补服务端地址、token、cookie 或请求头。返回 false 或异常时保留窗口供重试/复制；
返回 true 仅表示系统接受请求，不提示网页加载成功。等待期间不允许重复打开或关闭窗口。
个人阅读、共享/历史阅读、编辑预览均复用此行为，不修改笔记或 dirty 状态。
HTML 预览的链接列表也复用确认窗，可视化编辑器的导航策略不变。Dart 服务与 Widget 测试覆盖地址验证、
确认/取消、重复操作及平台失败，Android/iOS 系统应用跳转仍需真机验收。

## 富文本预览链接列表

SafeHtmlNoteBody 保留原有原生正文预览，在下方增加可展开的链接列表。
从同一次解析的 DOM 中读取 href，使用与预览一致的省略标签及 64 层深度限制，
按原文顺序去重并限制为 100 个地址；HTML 实体由解析器解码，不补服务端地址。
完整地址在 NoteLinkDialog 中展示，确认后复用 NoteLinkOpener 的校验与外部应用处理。
不支持的地址仍可查看/复制，任何链接都不在渲染或展开列表时启动外部应用。
列表只读，不触发保存或改变 dirty 状态，不改变 WebView 可视化编辑的导航拦截。
测试覆盖表格内链接、实体解码、去重、省略内容、不安全地址、数量上限和确认后调用。

## 附件原生打开

NoteFilesPage 的独立“打开附件”按钮通过 noteAttachment 沿用联网权限校验、cachedOnly 模式和大小限制。
AttachmentOpener 再次限制 32 MiB（允许空附件），在 getTemporaryDirectory 下独占的
`gemsnote-open-attachments/open-*` 目录写入安全文件名，然后调用 open_filex。
每次创建唯一目录，避免跨账号、同名附件或版本变化覆盖已交出的副本。
原生返回仅代表操作交接，不提示成功阅读；无处理应用等错误提供保存/分享替代。
下载后及临时文件写入后检查页面存活，失活不启动原生打开，并清理未交出的副本。

每次打开尽力清理本功能超过 24 小时的旧目录；不遍历或删除其他临时文件，
不在原生返回时立即删除副本，失败/不确定交接的副本也等待过期清理。
这些文件不属于 SQLite 的 64 MiB 配额，系统也可能提前回收；超过一天的副本不保证继续可读。
Android 使用私有缓存路径与插件 FileProvider，Manifest 合并显式移除插件自带的共享存储/媒体读取权限，
不需要扫描用户文件目录。iOS 使用插件 DocumentInteraction。

Android 模拟器专项先构建只在测试中使用的本地接收应用，再调用生产打开服务：

```sh
fixture=$(scripts/build_android_share_fixture.sh)
python3 scripts/test_android_attachment_open.py emulator-5554 "$fixture"
```

脚本拒绝真机，重新安装独立夹具后分别触发二进制和空附件，实际操作系统“打开方式”面板；
接收 Activity 从授权 URI 读取并记录文件，宿主精确核对安全文件名、MIME、读取授权和字节。
运行集成入口会覆盖普通应用 APK，结束后必须重新构建并安装 `lib/main.dart`。该专项不联网、
不使用账号，也不代表第三方应用、其他文件类型或真机兼容性。iOS 模拟器证据见下文。
本机原有 Gradle 压缩包损坏问题已修复；aapt 验证合并权限无共享存储/媒体读取权限。

iOS 模拟器专项使用生产 `AttachmentOpener` 和插件 DocumentInteraction，并创建仅供测试的
文档接收应用：

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  bash scripts/with_xcode.sh bash scripts/test_ios_attachment_open.sh <simulator-id>
```

UI 测试在 Quick Look 中点击系统提供的“拷贝到 OpenReceiver”，接收应用实际读取二进制及
空附件，再核对安全文件名和原件字节。脚本卸载接收应用，但集成入口会覆盖普通应用；结束后
必须重新构建、安装并启动 `lib/main.dart`。该专项不代表其他文档应用、iPad 或真机兼容性。

## 同步后资源缓存偏好

schema v8 新增 `account_cache_preferences`，以规范化服务器地址和用户 ID 为键，
保存默认关闭的同步后缓存开关。与其他偏好一样，不依赖账号快照的级联删除，
退出和重新同步保留；写入前在事务内校验账号缓存仍存在，不改变 dirty 或 USN。
v7 升级只建表，保留正文、默认编辑器和排序偏好。

工作区异步恢复设置，但恢复和开启开关都不启动下载。仍需成功同步或选择
“开始资源缓存”；菜单提示可能使用移动数据。读取失败关闭自动缓存并提供
重试入口，读写期间禁用切换和手动开始，保存失败保留原值并提示。
关闭成功后取消队列后续任务，在途请求不强制中断。持久化只保存偏好，
下载任务和运行锁持久保存。Android 开启自动缓存后使用 WorkManager 安排一次性续传和
15 分钟周期任务；前后台执行共用 SQLite 过期锁，避免两个 Flutter engine 同时处理同一账号。
iOS 通过 `background_tasks.dart` 接入 Workmanager 的 BGProcessing：
AppDelegate 在启动时注册 `com.github.gemsnote.resourceCache` 和
`com.github.gemsnote.noteSync`，Info.plist 声明同名许可标识及 `processing` 模式，
独立后台引擎通过 GeneratedPluginRegistrant 注册 SQLite、钥匙串等插件。
开启偏好时预约最早 15 分钟后的联网处理机会，转入后台时可请求更早处理；
这是最早执行时间提示，不是定时保证，实际唤醒由 iOS 决定。

每次后台运行先检查当前账号和 SQLite 中的偏好，符合条件才预约下次机会，
随后重新恢复安全存储中的会话并通过 API2 执行。任务数据不保存 token。
关闭偏好会取消对应待执行任务；过期请求即使被唤醒也会再次检查偏好。
保留已有钥匙串保护级别：锁屏时读取不可用则本次失败，后续机会继续重试。
前后台共用既有 SQLite 租约与持久队列；iOS 终止后台引擎后，通过租约过期恢复，
不能把调用调度 API 返回当作系统已接受或已执行任务的证明。
真机后台唤醒、锁屏/解锁、任务过期及长期恢复仍待验收。

验证：`flutter test test/data/default_editor_test.dart test/account_file_cache_page_test.dart`，
覆盖 v7 升级、账号隔离、重启/退出/快照替换、失败重试、保存等待期间禁用操作，
以及恢复设置不发起下载。原生生命周期与弱网仍需设备验收。

## 多账号切换

`AuthRepository.savedAccounts` 从账号缓存列举身份，并检查对应安全存储 token；
界面仅显示账号元数据。`switchAccount` 复用账号缓存键（服务器 + 用户 ID），
拒绝正在同步/上传、缺失缓存或凭据的切换，再事务激活目标账号；不会联网或清除 dirty。
`completeLogin` 在新快照写入后安全存储失败时回滚原活动身份，防止重启进入半完成的登录。

`AccountSwitcherPage` 从工作区入口先执行资源队列停止/等待，完成前不能返回或重复提交。
新登录仍复用原登录页，等待期间禁止系统返回；取消添加保持当前身份。
根节点为每次会话切换生成新工作区 key，包括同账号重新登录，避免遗留列表、计时器和分享状态。
根登录页提供恢复其他已登录账号的入口，不触发自动头像联网刷新。

`SharedTextInbox` 记录平台通道当前 owner，只有当前 owner 销毁才清理 handler，
覆盖 Flutter 替换工作区时新实例先初始化、旧实例后销毁的顺序。
此变更不修改分享内容和目标账号绑定规则。

相关验证：`test/data/account_switch_test.dart`、`test/account_switcher_page_test.dart`、
`test/shared_text_inbox_test.dart`。仍需 Android/iOS 安全存储与生命周期的设备验收。

## 已有笔记本离线编辑（schema v9）

notebooks.is_dirty 保存重命名和移动的待上传状态，标题/父级局部修改不会覆盖另一个字段。
SyncCoordinator 读取单份完整本地笔记本快照，对 dirty 节点及其父级链拓扑排序后上传，
正常增量/全量同步及退出前 uploadPending 共用此顺序。仍使用 `/api2/client/notebook/update`。
文件上传的 upload-only 路径不顺带上传其他笔记本，不改变现有附件上传范围。

API2 冲突后读取 afterUsn=原 USN 的笔记本增量，只有远端字段与提交目标完全一致时才能确认
可能丢失的上传回包。真实冲突、中断或无效响应保持 dirty；等待期间的新编辑只继承新的
基础 USN，下轮继续上传。

mergeChanges 在事务中拒绝覆盖 dirty 笔记本，cacheNotebook 同样检查；快照重置的
noteSnapshotFingerprint（历史命名保留）现在包含笔记和笔记本两张表，避免确认后
等待下载时的新笔记本修改被抹除。schema 升级只添加默认 0 的列，保留 IDs、dirty 笔记和游标。


## 目录删除、标签重命名与历史资源限制

空笔记本删除使用 `/api2/client/notebook/delete`，标签删除使用 `/api2/tag/deleteTag`，均通过 `runMetadataUpdate` 互斥并检查服务端同步状态。删除完成后正常增量同步，不直接推进同步游标；删除响应丢失可由后续同步恢复。

标签重命名由 API2 创建目标标签、事务替换本机笔记标签、正常上传/下载和删除旧目录项组成，覆盖回收站笔记，合并已有目标标签并去重。失败保留已暂存的 dirty 修改；同步后重试原重命名可继续。此流程不是服务端原子操作，跨设备同时改标签存在竞态，后续可用专用原子 API2 重命名接口改进。

完整历史恢复已接入 `/api2/note/restoreHistory`：只在联网且快照 FilesComplete=true 时提供，按当前缓存 USN 提交；同步互斥区内拒绝目标笔记 dirty、未同步新建及待处理附件上传。服务端验证原作者、版本与原件并恢复，客户端随后正常同步。正文恢复保持独立并支持离线。旧历史缺少完整清单或原件已丢失时不能执行完整恢复。


## Markdown Mermaid 预览

`markdown_mermaid.dart` 扩展围栏代码块，保持原生 Flutter Markdown、公式、图片和锚点阅读。
每篇文档按需创建一个本地 WebView，使用打包的 Mermaid 11.17.2 将图表转为 PNG，显示与缩放由 Flutter 处理。
同一文档复用渲染器，缓存最多 32 份结果；切换正文后销毁旧实例，不将生成图写入 SQLite 或正文。
单张 PNG 最大边 2048、总像素不超过 200 万。可点击放大并双指缩放，也可展开、复制源码。

仅渲染 `mermaid` 围栏，富文本和普通代码块行为不变。渲染失败保留源文，提示支持中文/英文。
每实例最多 32 个图块、每块 20,000 字符/500 行、连边上限 200。
禁用 Mermaid 配置指令/frontmatter、HTML、外部图片与点击链接；本地 HTML 的 CSP 阻止外部资源和网络连接。
WebView 仅提供返回 PNG 的 channel，不提供账号、token、API2 或文件操作 bridge。
离线渲染资源在 `assets/mermaid/`，作为独立移动仓库资源提交，因此普通 Flutter 构建不需要 Node 或服务端源码。

更新资源时，在服务端仓库（旁边存在 `mobile-app/`）执行：

```bash
npm ci --prefix frontend
npm run build:mermaid:mobile --prefix frontend
```

该命令同时生成 Web 与 mobile 的同版资源；`manifest.json` 记录版本和 SHA-256。
不要手改压缩后的 HTML；修改服务端的 `frontend/mermaid/renderer.ts` 后重新生成，并保留 LICENSE。

在 mobile 仓库验证：

```bash
flutter analyze --no-pub
flutter test --no-pub test/markdown_mermaid_test.dart test/markdown_reader_test.dart test/markdown_math_test.dart test/markdown_anchors_test.dart
flutter test --no-pub --no-uninstall integration_test/mermaid_preview_test.dart -d emulator-5554
```

集成测试只创建虚构笔记，不运行账号会话、不连接服务端、不访问用户数据库。iOS 可用同一测试入口在模拟器运行。
