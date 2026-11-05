import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/attachment_outbox.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/attachment_picker.dart';
import 'package:gemsnote/ui/attachment_outbox_page.dart';
import 'package:gemsnote/ui/note_files_page.dart';

import 'note_files_page_test.dart' show FilesRepository;

class FixedAttachmentPicker extends AttachmentPicker {
  @override
  Future<AttachmentUpload?> pick() async =>
      AttachmentUpload(name: 'draft.txt', bytes: Uint8List.fromList([1, 2, 3]));
}

class OutboxRepository extends FilesRepository {
  String state = 'uncertain';
  bool image = false;
  int inserts = 0;
  @override
  Future<void> insertStagedImage(StoredSession session, String id) async {
    inserts++;
    state = 'inserted';
  }

  bool removed = false;
  int writes = 0, uploads = 0, stages = 0;
  @override
  Future<List<PendingAttachment>> pendingAttachments(
    StoredSession session, {
    String? noteId,
  }) async => removed
      ? []
      : [
          PendingAttachment(
            id: 'task',
            noteId: 'note',
            name: 'draft.txt',
            size: 3,
            state: state,
            remoteId: '',
            kind: image ? 'image' : 'attachment',
          ),
        ];
  @override
  Future<void> retryUncertainAttachment(
    StoredSession session,
    String id,
  ) async {
    writes++;
    state = 'pending';
  }

  @override
  Future<void> removeStagedAttachment(StoredSession session, String id) async {
    writes++;
    removed = true;
  }

  @override
  Future<AttachmentUpload> stagedAttachment(
    StoredSession session,
    String id,
  ) async =>
      AttachmentUpload(name: 'draft.txt', bytes: Uint8List.fromList([1, 2, 3]));
  @override
  Future<bool> uploadStagedAttachment(StoredSession session, String id) async {
    uploads++;
    state = 'uploaded';
    return true;
  }

  @override
  Future<String> stageAttachment(
    StoredSession session,
    String noteId,
    AttachmentUpload file,
  ) async {
    stages++;
    expect(file.bytes, [1, 2, 3]);
    return 'task';
  }
}

void main() {
  final session = StoredSession(
    account: Account(
      userId: 'u',
      server: Uri.parse('https://example.test'),
      username: 'u',
      email: '',
      logo: '',
    ),
    token: 't',
  );
  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('附件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'uncertain task needs confirmation, upload does not run on restore or retry permission',
    (tester) async {
      final repo = OutboxRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentOutboxPage(repository: repo, session: session),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.uploads, 0);
      await choose(tester, '核实后允许重试');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.writes, 0);
      await choose(tester, '核实后允许重试');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(repo.uploads, 0);
      expect(repo.writes, 1);
      await choose(tester, '上传附件');
      await tester.tap(find.text('上传'));
      await tester.pumpAndSettle();
      expect(repo.uploads, 1);
      expect(find.textContaining('已上传，本地副本保留'), findsOneWidget);
      await choose(tester, '移除本地附件');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.removed, isFalse);
      await choose(tester, '移除本地附件');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(repo.removed, isTrue);
      expect(find.text('暂无暂存附件'), findsOneWidget);
    },
  );

  testWidgets(
    'offline file page can stage attachment without credentials or network upload',
    (tester) async {
      final repo = OutboxRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: NoteFilesPage(
            repository: repo,
            session: session,
            noteId: 'note',
            initialCachedOnly: true,
            attachmentPicker: FixedAttachmentPicker(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.listModes, [true]);
      final requests = repo.listModes.length;
      await tester.tap(find.byTooltip('本地附件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线添加附件'));
      await tester.pumpAndSettle();
      expect(repo.stages, 1);
      expect(repo.uploads, 0);
      expect(repo.listModes.length, requests);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('附件已保存到本机'), findsOneWidget);
    },
  );

  testWidgets('confirmed image recovers insertion without uploading again', (
    tester,
  ) async {
    final repo = OutboxRepository()
      ..image = true
      ..state = 'uploaded';
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentOutboxPage(repository: repo, session: session),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester, '插入到笔记末尾');
    await tester.pumpAndSettle();
    expect(repo.inserts, 1);
    expect(repo.uploads, 0);
    expect(find.textContaining('已插入本地正文'), findsOneWidget);
    await tester.tap(find.byTooltip('附件操作'));
    await tester.pumpAndSettle();
    expect(find.text('上传并插入图片'), findsNothing);
    expect(find.text('插入到笔记末尾'), findsNothing);
  });
}
