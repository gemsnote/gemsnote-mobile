import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/sharing_navigation.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/shared_by_me_page.dart';
import 'package:gemsnote/ui/note_reader_page.dart';

class OutgoingRepository implements AuthRepository {
  bool offline = false;
  @override
  Future<SharingNavigation> sharingNavigation(
    StoredSession session, {
    bool refresh = false,
  }) async {
    if (refresh && offline) throw StateError('offline');
    return const SharingNavigation(
      recipients: [
        SharingRecipient(
          userId: 'reader',
          username: 'Alice',
          noteIds: ['mine'],
        ),
      ],
    );
  }

  @override
  Future<List<Note>> notes(
    String accountId, {
    String? notebookId,
    bool starredOnly = false,
    bool trashOnly = false,
  }) async => [
    Note.fromJson({
      'NoteId': 'mine',
      'Title': 'My note',
      'IsMarkdown': true,
      'UpdatedTime': '2026-10-30 12:00',
    }),
  ];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
    'cached recipients render while online refresh is still pending',
    (tester) async {
      final remote = Completer<List<String>>();
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: Note.fromJson({
              'NoteId': 'mine',
              'Title': 'My note',
              'IsMarkdown': true,
            }),
            loadCachedSharing: () async => ['Alice'],
            loadSharing: () => remote.future,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已共享给：Alice'), findsOneWidget);
      remote.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('已共享给：Alice'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'outgoing sharing displays usernames, note format and cached notes on failure',
    (tester) async {
      final repo = OutgoingRepository()..offline = true;
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: SharedByMePage(
            repository: repo,
            session: StoredSession(
              account: Account(
                userId: 'owner',
                server: Uri.parse('https://test.invalid'),
                username: 'owner',
                email: '',
                logo: '',
              ),
              token: 'test',
            ),
            openNote: (note) async {
              opened = note.noteId;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.textContaining('以下显示本地缓存'), findsOneWidget);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      expect(find.text('MD 2026-10-30 12:00'), findsOneWidget);
      await tester.tap(find.text('My note'));
      await tester.pumpAndSettle();
      expect(opened, 'mine');
    },
  );
  testWidgets(
    'own reader shows recipients and refreshes after share management',
    (tester) async {
      var recipients = ['Alice'];
      var managed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: Note.fromJson({
              'NoteId': 'mine',
              'Title': 'My note',
              'IsMarkdown': true,
            }),
            loadSharing: () async => recipients,
            onManageSharing: () async {
              managed = true;
              recipients = ['Bob'];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已共享给：Alice'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('共享设置'));
      await tester.pumpAndSettle();
      expect(managed, true);
      expect(find.text('已共享给：Bob'), findsOneWidget);
    },
  );
}
