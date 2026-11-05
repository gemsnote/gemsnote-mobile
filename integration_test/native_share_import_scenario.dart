import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/session/session_store.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/shared_text_inbox.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:gemsnote/ui/shared_text_dialog.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void runShareImport({required bool supported}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('SHARE_IMPORT_RUN');
  const androidIds = String.fromEnvironment('SHARE_IMPORT_IDS');
  testWidgets('native inbox claim, offline import, retry and acknowledge', (
    tester,
  ) async {
    if (Platform.isIOS) {
      expect(RegExp(r'^[0-9a-f]{22}$').hasMatch(run), isTrue);
    }
    final ids = Platform.isAndroid
        ? androidIds.split(',')
        : [for (var i = 0; i < 3; i++) '${run}0$i'];
    expect(ids, hasLength(Platform.isAndroid ? 5 : 3));
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.every((id) => RegExp(r'^[0-9a-f]{24}$').hasMatch(id)), true);
    final directory = await (await getTemporaryDirectory()).createTemp(
      'share-import-',
    );
    final path = '${directory.path}/notes.sqlite';
    var db = await AppDatabase.open(databasePath: path);
    final inbox = SharedTextInbox();
    final client = MockClient(
      (_) async => throw StateError('Import must stay offline'),
    );
    final api = Api2Client(httpClient: client);
    final session = StoredSession(
      account: Account(
        userId: 'fixture',
        server: Uri.parse('https://import-test.invalid'),
        username: 'fixture',
        email: '',
        logo: '',
      ),
      token: 'unused-test-token',
    );
    AuthRepository repository() => AuthRepository(
      api,
      db,
      const SecureSessionStore(),
      SyncCoordinator(api, db),
    );
    var repo = repository();
    try {
      await db.replaceSnapshot(
        account: session.account,
        notebooks: [
          Notebook.fromJson({'NotebookId': 'book', 'Title': 'Test notebook'}),
        ],
        notes: [],
        tags: [],
        lastSyncUsn: 2,
      );
      await inbox.start();
      for (final id in ids) {
        expect(inbox.error, isNull);
        final source = inbox.pending!;
        // Never claim or delete another share, even on an incorrectly prepared simulator.
        expect(source.id, id);
        expect(source.accountKey, isEmpty);
        if (source.hasResource) {
          await expectLater(
            inbox.readResource(source, session.account.cacheKey),
            throwsA(isA<PlatformException>()),
          );
        }
        await inbox.claim(source, session.account.cacheKey);
        await inbox.refresh();
        final claimed = inbox.pending!;
        expect(claimed.accountKey, session.account.cacheKey);
        await expectLater(
          inbox.claim(claimed, 'another-account'),
          throwsA(isA<PlatformException>()),
        );
        Uint8List? bytes;
        if (source.hasResource) {
          await expectLater(
            inbox.readResource(claimed, 'another-account'),
            throwsA(isA<PlatformException>()),
          );
          bytes = await inbox.readResource(claimed, session.account.cacheKey);
          expect(bytes.length, source.resourceSize);
        }
        var imports = 0;
        var acknowledgments = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<Note>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => SharedTextDialog(
                      source: claimed,
                      notebooks: [
                        Notebook.fromJson({
                          'NotebookId': 'book',
                          'Title': 'Test notebook',
                        }),
                      ],
                      accountLabel: 'fixture · https://import-test.invalid',
                      canImport: true,
                      onImport: (edited, book) async {
                        imports++;
                        expect(book, 'book');
                        await inbox.claim(source, session.account.cacheKey);
                        final resource = source.hasResource
                            ? await inbox.readResource(
                                source,
                                session.account.cacheKey,
                              )
                            : null;
                        return repo.importSharedText(
                          session,
                          edited,
                          book,
                          resourceBytes: resource,
                        );
                      },
                      onAcknowledge: () async {
                        acknowledgments++;
                        // Deliberately fail only the first cleanup attempt. Import and
                        // the second acknowledgment both use real production storage.
                        if (acknowledgments == 1) {
                          throw StateError('Injected cleanup failure');
                        }
                        await inbox.acknowledge(claimed);
                      },
                    ),
                  ),
                  child: const Text('Open share'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open share'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '保存笔记'))
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byType(TextField).first,
          'Dialog title $id',
        );
        await tester.enterText(
          find.widgetWithText(TextField, '分享正文'),
          'Dialog body $id',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Test notebook'));
        await tester.tap(find.text('Test notebook'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存笔记'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Injected cleanup failure'), findsOneWidget);
        expect(find.text('重试清理'), findsOneWidget);
        expect(imports, 1);
        expect(acknowledgments, 1);
        expect(inbox.pending?.id, id);
        expect(
          tester.widget<TextField>(find.byType(TextField).first).enabled,
          false,
        );
        final note = (await db.searchableNote(session.account.cacheKey, id))!;
        expect(note.noteId, id);
        expect(note.title, 'Dialog title $id');
        expect(note.content, 'Dialog body $id');
        expect(note.notebookId, 'book');
        expect(await db.pendingNoteIds(session.account.cacheKey), contains(id));
        // Native acknowledgment has not happened. Reopen the real SQLite file
        // and retry after an edit to model a process death at this boundary.
        await db.saveEditedText(
          session.account.cacheKey,
          id,
          'Edited',
          'Preserved $id',
        );
        await db.raw.close();
        db = await AppDatabase.open(databasePath: path);
        repo = repository();
        final retry = await repo.importSharedText(
          session,
          claimed,
          'book',
          resourceBytes: bytes,
        );
        expect(retry.title, 'Edited');
        expect(retry.content, 'Preserved $id');
        if (source.hasResource) {
          final task = (await repo.pendingAttachments(session))
              .where((item) => item.noteId == id)
              .single;
          expect(task.isImage, source.resourceKind == 'image');
          expect(task.state, 'pending');
          final staged = await repo.stagedAttachment(session, task.id);
          if (!task.isImage) {
            expect(staged.bytes, bytes);
            if (source.resourceName.endsWith('.bin')) {
              expect(staged.bytes, [0, 1, 2, 127, 128, 255]);
            }
          }
          expect(staged.bytes, isNotEmpty);
        }
        await tester.tap(find.text('重试清理'));
        await tester.pumpAndSettle();
        expect(find.byType(SharedTextDialog), findsNothing);
        expect(imports, 1);
        expect(acknowledgments, 2);
        expect(inbox.pending?.id, isNot(id));
        if (source.hasResource) {
          await expectLater(
            inbox.readResource(claimed, session.account.cacheKey),
            throwsA(isA<PlatformException>()),
          );
        }
      }
      expect((await db.notes(session.account.cacheKey)).length, ids.length);
      expect(
        (await repo.pendingAttachments(session)).length,
        Platform.isAndroid ? 3 : 2,
      );
      expect(await db.lastSyncUsn(session.account.cacheKey), 2);
      expect(inbox.pending, isNull);
    } finally {
      inbox.dispose();
      client.close();
      if (db.raw.isOpen) await db.raw.close();
      await directory.delete(recursive: true);
    }
  }, skip: !supported || (Platform.isIOS ? run.isEmpty : androidIds.isEmpty));
}
