import '../l10n/app_strings.dart';

import 'dart:convert';
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import '../domain/models/note.dart';

/// Shares the displayed source as plain text, without media, credentials or URLs
/// added by the app. The receiving application controls what happens next.
class NoteSharer {
  NoteSharer({
    this.strings = const AppStrings(Locale('zh')),
    Future<ShareResult> Function(ShareParams)? share,
  }) : _share = share ?? SharePlus.instance.share;
  final AppStrings strings;
  final Future<ShareResult> Function(ShareParams) _share;

  Future<void> share(Note note, Rect origin) async {
    final title = note.title.trim().isEmpty
        ? strings.label('未命名笔记')
        : note.title;
    final text = '$title\n\n${note.content}';
    // Keep text intents well below Android's IPC transaction limit. Larger
    // notes can use the existing source-file export instead; never truncate.
    if (utf8.encode(text).length > 256 * 1024) {
      throw StateError('分享文本超过 256 KiB，请使用导出原文');
    }
    if (!origin.isFinite || origin.isEmpty) throw StateError('无效的分享位置');
    await _share(
      ShareParams(text: text, subject: title, sharePositionOrigin: origin),
    );
    // A selected share target is not proof of delivery. No success claim.
  }
}
