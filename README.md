# Gemsnote Mobile

珠玑笔记移动客户端，使用 Flutter 重构，同时支持 Android 和 iOS。客户端只使用 Gemsnote API2，基础功能支持 v1.0.0，v1.1.0 增加创建幂等和上传回执恢复；
首次登录会从服务端建立新的 SQLite 离线缓存，不迁移旧 Android 客户端的本地数据库。

移动端主体迁移已完成，笔记本删除和全局标签管理已接入 API2；在线历史正文与附件恢复已接入新的服务端快照合同：

- 已完成旧 Android 核心功能的 Flutter 迁移
- 创建 Flutter Android/iOS 双平台工程
- API2 登录、服务端与最低客户端版本校验
- 笔记本、笔记正文和标签的首次全量下载
- 按“服务端地址 + 用户 ID”隔离的 SQLite 离线缓存
- token 安全存储和离线恢复登录状态
- 完整离线笔记、笔记本、标签、搜索、历史、资源和冲突处理
- Markdown 与富文本编辑、图片和附件、系统分享及 Android 后台同步
- 共享内容统一只读，支持“我共享的”、个人笔记本归属和独立副本；复制正文、图片和附件后可自行编辑
- 账号支持头像、用户名、密码与邮箱验证，邮件发送进度及中英文提示

开发环境与验证命令见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

Android 签名构建与版本 tag 自动发布见 [docs/RELEASE.md](docs/RELEASE.md)。普通分支 push/PR 只运行检查与测试；iOS 正式发布仍待实现。

本项目源自 Leanote Android 客户端，网络、存储和界面层已使用 Flutter 重新实现。
旧 Android 归档已移出当前版本，可从删除前的 Git 提交 `bdd25d6` 查阅。
项目许可证保留在 [LICENSE](LICENSE)。
