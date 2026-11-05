import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/sharing_navigation.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/note_sharing_dialog.dart';

class SharingRepository implements AuthRepository {
  final sent = <String>[];
  @override
  Future<List<Map<String, Object?>>> shareMembers(
    StoredSession session,
    Note note,
  ) async => [];
  @override
  Future<SharingNavigation> sharingNavigation(
    StoredSession session, {
    bool refresh = false,
  }) async => const SharingNavigation(
    suggestions: [
      SharingRecipient(userId: 'past', username: 'past-reader', noteIds: []),
    ],
    recipients: [
      SharingRecipient(userId: 'active', username: 'alice', noteIds: ['note']),
    ],
  );
  @override
  Future<void> shareNote(StoredSession session, Note note, String email) async {
    sent.add(email.trim());
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  for (final english in [false, true]) {
    testWidgets(
      'accepts username/email, selects historical users, rejects blank: English=$english',
      (tester) async {
        final repo = SharingRepository();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(english ? 'en' : 'zh'),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: NoteSharingDialog(
                repository: repo,
                session: StoredSession(
                  account: Account(
                    userId: 'owner',
                    server: Uri.parse('https://example.test'),
                    username: 'owner',
                    email: '',
                    logo: '',
                  ),
                  token: 'test',
                ),
                note: Note.fromJson({
                  'NoteId': 'note',
                  'UserId': 'owner',
                  'Usn': 1,
                }),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        final submit = find.text(english ? 'Read-only sharing' : '只读共享');
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(repo.sent, isEmpty);
        expect(
          find.text(english ? 'Enter a username or email' : '请输入用户名或邮箱'),
          findsOneWidget,
        );
        await tester.enterText(field, 'past');
        await tester.pumpAndSettle();
        await tester.tap(find.text('past-reader'));
        await tester.pumpAndSettle();
        expect(repo.sent, isEmpty);
        expect(tester.widget<TextField>(field).controller!.text, 'past-reader');
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(repo.sent, ['past-reader']);
        await tester.enterText(field, 'alice');
        await tester.pumpAndSettle();
        await tester.tap(find.text('alice').last);
        await tester.pumpAndSettle();
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(repo.sent.last, 'alice');
        await tester.enterText(field, ' mail@example.test ');
        await tester.pumpAndSettle();
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(repo.sent.last, 'mail@example.test');
        expect(tester.takeException(), null);
      },
    );
  }
}
