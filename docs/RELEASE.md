# 移动端发布

普通分支 push、PR 和手动 CI 只运行检查与测试。只有推送 `1.0.0` 这类无 `v`
的正式 tag，才执行 `.github/workflows/release.yml`。当前自动发布仅覆盖 Android；
iOS 正式签名和发布尚未实现，不发布模拟器包冒充 IPA。

云端固定使用 Flutter 3.47.5，并从默认的 `pub.dev` 安装依赖，与
`pubspec.lock` 记录的来源保持一致。CI 和发布均启用 `--enforce-lockfile`，
不会自动升级依赖。切换 `PUB_HOSTED_URL` 会改变锁定来源，不能与现有锁文件
混用；本地若设置了镜像，可用 `env -u PUB_HOSTED_URL flutter pub get --enforce-lockfile`
执行同样的严格校验，这不会修改 shell 中原有的镜像设置。

发布构建保留 Flutter 默认的依赖准备步骤，不添加 `--no-pub`：当前固定版本
会在该步骤重新生成 release 插件注册文件，排除 `integration_test` 等开发依赖。
只先执行 `pub get` 再用 `build --release --no-pub`，可能把测试插件注册带入正式
编译，导致 `IntegrationTestPlugin` 类不存在。静态分析和普通测试仍可用 `--no-pub`。

## 版本与产物

版本在 `pubspec.yaml` 的 `version: 1.0.0+1` 维护：tag 对应 `1.0.0`，
`+1` 是安装包构建号。发布时递增构建号；tag 必须指向包含对应版本配置的提交。
工作流先严格校验 tag，再运行全量测试，然后用 Java 17 构建签名 Release：

- `gemsnote-<version>-android.apk`：Android 安装包。
- `gemsnote-<version>-android.aab`：应用商店上传用 bundle，不直接安装。
- `SHA256SUMS`：上述文件的 SHA-256 校验值。

构建通过后创建 GitHub Release；不会自动上传到 Google Play。
同名 Release 已存在时发布命令失败，不覆盖旧产物，也不移动 tag。
构建 artifact 保留 7 天；GitHub Release 附件不受此 artifact 保留期影响。

## Android 签名

妥善保存自己的正式 keystore；不要提交到 Git，不要使用调试密钥正式分发。
签名生成和备份要求参考 [Flutter 官方 Android 发布指南](https://docs.flutter.dev/deployment/android)。
应用更新须保持合适的签名身份，不能为每个版本生成不同的密钥。
Google Play 的应用签名密钥与上传密钥可能不同；使用上传密钥签名的 GitHub APK
不一定能覆盖安装 Play 分发版本，应事先确定分发渠道和签名方案。

在 mobile 仓库 Settings → Secrets and variables → Actions 配置：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |

Base64 不是加密，同样必须作为 Secret 管理。工作流只在 tag 构建中将密钥解码到
runner 临时目录，构建后清理；不会把它打包进 artifact。缺失凭据或无效密钥导致失败，
不会回退到 debug 签名。尚未在本仓库远端配置或上传任何真实密钥。

## 本地构建

准备 Flutter 3.47.5、Java 17 与 Android SDK，在本仓库根目录执行检查：

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

通过本地安全方式设置以下环境变量（不要把密码写进脚本、命令历史或文档）：
`ANDROID_KEYSTORE_PATH`（keystore 绝对路径）、`ANDROID_KEYSTORE_PASSWORD`、
`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。然后执行统一脚本：

```sh
bash scripts/build_release.sh android
```

如果 shell 配置了 Pub 镜像，使用
`env -u PUB_HOSTED_URL bash scripts/build_release.sh android`，使脚本中的依赖
校验与构建都使用锁文件指定的来源。

输出分别是 `build/app/outputs/flutter-apk/app-release.apk` 和
`build/app/outputs/bundle/release/app-release.aab`。Gradle 不读取 `key.properties`，
只使用上述环境变量；debug 构建不需要正式签名参数。

在 macOS 上完成 Apple Team、证书和 provisioning profile 配置后，可直接构建 IPA：

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  bash scripts/build_release.sh ios
```

使用 `all` 会依次构建 Android 和 iOS。脚本默认执行锁文件校验、静态检查和完整测试；
已经完成同一提交的检查时可设置 `SKIP_CHECKS=1`。IPA 默认使用 `app-store` 导出方式，
也可通过 `IOS_EXPORT_METHOD` 或 `IOS_EXPORT_OPTIONS_PLIST` 调整。所有产物复制到
`release/` 并生成 `SHA256SUMS`。正式 HTTPS 深链接域名可通过
`GEMSNOTE_LINK_HOST=notes.example` 传入。

配置签名后先本地验证，再提交版本变更并推送新 tag：

```sh
git tag -a 1.0.0 -m "Gemsnote Mobile 1.0.0"
git push origin 1.0.0
```

不要覆盖已有 tag；失败先查 Actions 日志，修复代码后使用新的版本 tag。

## 发布前验收

Flutter 功能迁移已完成，正式发布仍需按目标平台完成签名和设备验收：

- 核对 application ID、Bundle ID、发布版本、构建号及正式签名，验证旧版覆盖安装后登录信息和本地数据保留。
- 验证真实设备上的编辑器输入与选区、系统分享、文件选择、相机、附件打开、生物解锁和应用生命周期。
- 验证弱网、大数据量、跨端并发、后台同步，以及锁屏、系统回收和厂商后台限制后的恢复。
- 配置正式深链接域名和服务端关联文件，验证实际域名的链接跳转。
- Android 需验证签名 APK/AAB 及 GitHub Release 发布；iOS 需另行完成正式签名、归档和发布，当前 GitHub Actions 不包含 iOS 构建。

测试命令与设备数据保留要求见 [DEVELOPMENT.md](DEVELOPMENT.md)，深链接配置见 [DEEP_LINKS.md](DEEP_LINKS.md)。
