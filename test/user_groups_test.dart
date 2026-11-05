import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/user_group.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/ui/user_groups_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class GroupsRepository implements AuthRepository {
  final identities = <String>[];
  final members = <GroupMember>[];
  String? failure;
  String title = 'My group';
  bool deleted = false;
  @override
  Future<List<UserGroup>> groups(StoredSession session) async => [
    if (!deleted)
      UserGroup(
        groupId: 'mine',
        ownerId: 'me',
        title: title,
        members: List.of(members),
      ),
    const UserGroup(groupId: 'other', ownerId: 'other', title: 'Other group'),
  ];
  @override
  Future<void> addGroupMember(
    StoredSession session,
    String id,
    String identity,
  ) async {
    expect(id, 'mine');
    identities.add(identity);
    if (failure != null) throw ApiException(failure!);
    members.add(
      GroupMember(
        userId: 'reader',
        username: identity.contains('@') ? 'Reader' : identity,
        email: 'reader@example.test',
      ),
    );
  }

  @override
  Future<void> renameGroup(
    StoredSession session,
    String id,
    String title,
  ) async {
    this.title = title;
  }

  @override
  Future<void> removeGroupMember(
    StoredSession session,
    String id,
    String userId,
  ) async {
    members.removeWhere((m) => m.userId == userId);
  }

  @override
  Future<void> deleteGroup(StoredSession session, String id) async {
    deleted = true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final session = StoredSession(
    account: Account(
      userId: 'me',
      server: Uri.parse('https://current.test/'),
      username: 'Me',
      email: '',
      logo: '',
    ),
    token: 'current-token',
  );
  test('API2 group actions keep current host, Bearer and identity field; empty members parse', () async {
    final seen = <String>[];
    final api = Api2Client(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'current.test');
        expect(request.headers['Authorization'], 'Bearer current-token');
        expect(request.url.path, startsWith('/api2/'));
        if (request.url.path == '/api2/groups') {
          expect(request.method, 'GET');
          return http.Response(
            jsonEncode([
              {
                'GroupId': 'g',
                'UserId': 'me',
                'Title': 'Readers',
                'Users': null,
              },
            ]),
            200,
          );
        }
        expect(request.method, 'POST');
        if (request.url.path.endsWith('/addUser')) {
          expect(request.bodyFields['groupId'], 'g');
          seen.add(request.bodyFields['email']!);
        }
        return http.Response('{"Ok":true}', 200);
      }),
    );
    expect(
      (await api.groups(
        server: session.account.server,
        token: session.token,
      )).single.members,
      isEmpty,
    );
    for (final identity in [
      ' Alice ',
      ' reader@example.test ',
      'abcdef0123456789abcdef01',
    ]) {
      await api.addGroupMember(
        server: session.account.server,
        token: session.token,
        groupId: 'g',
        identity: identity,
      );
    }
    expect(seen, ['Alice', 'reader@example.test', 'abcdef0123456789abcdef01']);
  });

  for (final english in [false, true]) {
    testWidgets(
      'group management accepts usernames/email and localizes failures: $english',
      (tester) async {
        final repo = GroupsRepository();
        final strings = AppStrings(Locale(english ? 'en' : 'zh'));
        await tester.pumpWidget(
          MaterialApp(
            locale: strings.locale,
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              AppStrings.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            home: UserGroupsPage(repository: repo, session: session),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('My group'));
        await tester.pumpAndSettle();
        Future<void> add() async {
          await tester.tap(find.text(strings.text('groupAddMember')));
          await tester.pumpAndSettle();
        }

        Future<void> submit(String input) async {
          await tester.enterText(find.byType(TextField), input);
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.widgetWithText(
                FilledButton,
                strings.text('groupAddMember'),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await add();
        expect(
          tester.widget<TextField>(find.byType(TextField)).keyboardType,
          TextInputType.text,
        );
        await submit('   ');
        expect(repo.identities, isEmpty);
        expect(
          find.text(strings.text('shareRecipientRequired')),
          findsOneWidget,
        );
        await submit(' Alice ');
        expect(repo.identities, ['Alice']);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Alice'), findsOneWidget);
        await add();
        repo.failure = 'userExistsInGroup';
        await submit('reader@example.test');
        expect(find.text(strings.text('groupDuplicate')), findsOneWidget);
        repo.failure = 'userNotExists';
        await submit('missing');
        expect(find.text(strings.text('groupUserMissing')), findsOneWidget);
        repo.failure = null;
        await submit('second@example.test');
        expect(repo.identities.last, 'second@example.test');
        expect(find.byType(AlertDialog), findsNothing);
        await tester.ensureVisible(find.text('Other group'));
        await tester.tap(find.text('Other group'));
        await tester.pumpAndSettle();
        expect(find.text(strings.text('groupReadOnly')), findsOneWidget);
        expect(
          find.text(strings.text('groupAddMember')),
          findsOneWidget,
        ); // own group only
      },
    );
  }
  testWidgets('group rename, remove and delete refresh the displayed catalog', (
    tester,
  ) async {
    final repo = GroupsRepository()
      ..members.add(
        const GroupMember(
          userId: 'reader',
          username: 'Reader',
          email: 'reader@example.test',
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: UserGroupsPage(repository: repo, session: session),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('My group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' Renamed ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsOneWidget);
    await tester.tap(find.byTooltip('移除成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('Reader'), findsNothing);
    await tester.tap(find.text('删除分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsNothing);
  });
}
