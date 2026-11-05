# 界面文案

`messages.json` 是中文 / 英文文案来源，`lib/l10n/messages.dart` 是生成结果。从 mobile-app 目录执行：

```sh
dart run tool/localization/migrate.dart --generate
dart format lib/l10n/messages.dart
flutter test test/localization_test.dart
```

增加文案时优先使用描述性 key；现有 mNNNN key 为初次 AST 迁移生成的稳定标识，不重新排序或编号。`{0}` 等占位符与参数一一对应，中英文必须具有相同占位符集合。生成器拒绝遗漏的英文翻译。测试同时核对生成结果与 JSON。

`tr(context, key, arguments)` 在 build 中建立语言依赖；初始化与事件处理用 `trNow` / `AppStrings.snapshot`，避免 initState 建立继承依赖。只对固定枚举使用 `trLabel`；只对应用生成的状态或错误使用 `trMessage`。笔记标题、正文、服务端消息及插值中的用户数据不做全文替换。底层异常在插值处按已知错误文案翻译，未知异常原样保留。

`--rewrite`、`--fix-context`、`--errors` 是首轮迁移辅助工具，修改前审阅差异，不作为日常生成步骤。Android 系统入口文案位于 values / values-zh/strings.xml，原生语言副本只保存 system/zh/en，不重启 Activity；Flutter 数据库是设置来源，原生副本更新失败会提示重试。
