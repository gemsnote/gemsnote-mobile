class ApiException implements Exception {
  const ApiException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() => switch (code) {
    'mailQueueNotConfigured' => '邮件任务队列未配置，请联系管理员。',
    'mailQueueUnavailable' => '无法连接邮件任务队列，请联系管理员检查 Redis。',
    'mailNotConfigured' => 'SMTP 配置不完整或无效，请联系管理员。',
    'mailRateLimited' => '请等待 60 秒后再发送验证邮件。',
    'mailSiteURLInvalid' => '站点 URL 未正确配置，无法生成验证链接。',
    'mailTemplateInvalid' => '邮件模板未配置或无效，请联系管理员。',
    'mailTokenFailed' => '无法创建邮箱验证凭据，请稍后重试。',
    'mailTaskNotFound' => '邮件任务不存在或记录已过期，请重新发送。',
    'mailTaskExpired' => '邮件任务超时或未被处理，请联系管理员检查邮件 worker。',
    'mailAuthenticationFailed' => '邮件发送失败：SMTP 认证失败，请管理员检查用户名和密码。',
    'mailRecipientRejected' => '邮件发送失败：邮件服务器拒绝收件地址，请检查新邮箱。',
    'mailConnectionFailed' => '邮件发送失败：连接邮件服务器失败或超时，请管理员检查 SMTP 配置。',
    'mailDeliveryFailed' => '邮件发送失败：SMTP 或加密连接异常，请管理员检查邮件服务。',
    'emailUnchanged' => '新邮箱不能与当前邮箱相同。',
    'invalidEmail' => '请输入有效的邮箱地址。',
    'wrongPassword' => '当前密码不正确。',
    'notebookNotSynced' => '请先同步目标笔记本，再移动或复制共享笔记',
    'noteNotShareable' => '请先同步此笔记；只能共享自己的有效笔记',
    'shareFailed' => '共享操作失败，请刷新后重试',
    'sharingLoadFailed' => '无法读取共享状态，请稍后重试',

    'imageAlreadyReferenced' => '图片已被笔记或历史版本引用，不能清理',
    'uploadNotFound' => '未找到该图片的上传回执，请核实后重试',
    'uploadAlreadyCleaned' => '此上传已经清理，请用本地原件新建上传任务',
    'creationKeyDeleted' => '该笔记本已在服务端删除，请核实本地创建任务',
    'creationKeyUnavailable' => '笔记本创建键不可用，请核实本地创建任务',
    'sharedContentChanged' => '共享笔记已更新，请刷新列表后重试',
    'historyFileMissing' => '历史文件已丢失，无法完整恢复此版本',
    'historyFilesUnknown' => '此历史版本缺少完整附件清单，仅支持恢复正文',
    'historyRestoreFailed' => '恢复失败，请刷新笔记并检查历史记录后重试',
    _ => code,
  };
}
