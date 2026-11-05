# 移动端深链接

移动端支持以下两类账号绑定链接，其中 `note-id` 必须是 24 位十六进制 ID，`user` 必须是目标账号的服务端用户 ID：

```text
gemsnote://note/<note-id>?server=https%3A%2F%2Fnotes.example%2F&user=<user-id>
gemsnote://shared/<note-id>?server=https%3A%2F%2Fnotes.example%2F&user=<user-id>
https://notes.example/app/note/<note-id>?user=<user-id>
https://notes.example/app/shared/<note-id>?user=<user-id>
```

应用只打开与当前账号的规范化服务器地址和用户 ID 同时匹配的链接。未登录时链接保留在内存中，登录后再处理；普通笔记不在本地时先同步一次，共享链接始终进入只读页面。非法 ID、包含服务器凭据的地址、跨服务器、跨账号、已删除和已撤权目标均拒绝。

`gemsnote://` 在 Android 和 iOS 中直接可用。经过验证的 HTTPS App Links / Universal Links 需要每个自托管域名参与部署：

- Android 构建传入 `-PGEMSNOTE_LINK_HOST=notes.example`，并由该域名发布 `/.well-known/assetlinks.json`，内容绑定正式 application ID 与签名证书摘要。
- iOS 构建把 `GEMSNOTE_LINK_HOST` 设为同一域名，并由该域名发布 `/.well-known/apple-app-site-association`，内容绑定正式 Team ID 和 Bundle ID。

仓库默认使用保留域名 `links.gemsnote.invalid`，避免开发包声明任意真实站点。服务端关联文件依赖实际域名与发布证书，不属于客户端仓库，也不能由支持任意自托管服务器的单个安装包在运行时动态增加。
