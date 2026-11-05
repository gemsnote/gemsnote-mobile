import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/session/session_store.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

class _ScopedSessions implements SessionStore {
  const _ScopedSessions(this.run);
  final String run;
  static const storage = SecureSessionStore();
  String key(String account) => 'api2-device:$run:$account';
  @override
  Future<void> write(String userId, String token) =>
      storage.write(key(userId), token);
  @override
  Future<String?> read(String userId) => storage.read(key(userId));
  @override
  Future<void> delete(String userId) => storage.delete(key(userId));
}

class _LocalApi2 extends http.BaseClient {
  final inner = http.Client();
  bool offline = false;
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    if (offline) {
      throw StateError('Offline restore attempted a network request');
    }
    if (request.url.host != (Platform.isAndroid ? '10.0.2.2' : '127.0.0.1') ||
        request.url.port != 19090 ||
        !request.url.path.startsWith('/api2/')) {
      throw StateError('Request outside disposable API2 server');
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('API2_TEST_RUN');
  const phase = String.fromEnvironment('API2_TEST_PHASE');
  testWidgets('real API2 native session across process restart: $phase', (
    tester,
  ) async {
    expect(Platform.isIOS || Platform.isAndroid, isTrue);
    final serverAddress = Platform.isAndroid
        ? 'http://10.0.2.2:19090'
        : 'http://127.0.0.1:19090';
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(run), isTrue);
    expect(['seed', 'resume'], contains(phase));
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/api2-device-$run');
    final marker = File('${directory.path}/fixture.json');
    if (phase == 'seed') {
      expect(await directory.exists(), isFalse);
      await directory.create();
    } else {
      expect(await marker.exists(), isTrue);
    }
    final database = await AppDatabase.open(
      databasePath: '${directory.path}/notes.sqlite',
    );
    final client = _LocalApi2()..offline = phase == 'resume';
    final api = Api2Client(httpClient: client);
    const sessions = _ScopedSessions(run);
    final repo = AuthRepository(
      api,
      database,
      sessions,
      SyncCoordinator(api, database),
    );
    var completed = false;
    try {
      if (phase == 'seed') {
        final pending = await repo.beginLogin(
          serverAddress: serverAddress,
          identity: 'admin',
          password: 'gemsnote',
        );
        expect(pending.hasCache, isFalse);
        expect(await sessions.read(pending.session.account.cacheKey), isNull);
        final session = await repo.completeLogin(pending, resetCache: false);
        await repo.saveNotebook(session, title: 'Native session $run');
        final notebook = (await repo.notebooks(session.account.cacheKey))
            .singleWhere((book) => book.title == 'Native session $run');
        client.offline = true;
        final before = client.requests;
        final draft = await database.createLocalNote(
          account: session.account,
          notebookId: notebook.notebookId,
          isMarkdown: true,
          title: '冷启动离线笔记 $run',
          content: '第一阶段离线正文 📝',
        );
        expect(client.requests, before);
        expect(
          await database.pendingNoteIds(session.account.cacheKey),
          contains(draft.noteId),
        );
        await marker.writeAsString(
          jsonEncode({
            'account': session.account.cacheKey,
            'notebook': notebook.notebookId,
            'note': draft.noteId,
            'pid': pid,
          }),
          flush: true,
        );
      } else {
        final fixture = jsonDecode(await marker.readAsString()) as Map;
        // The host terminates the first process between these two test runs.
        expect(pid, isNot(fixture['pid']));
        final restored = await repo.restore();
        expect(restored, isNotNull);
        final session = restored!;
        final account = session.account.cacheKey;
        expect(account, fixture['account']);
        expect(client.requests, 0);
        final note = (await database.searchableNote(
          account,
          fixture['note'] as String,
        ))!;
        expect(note.content, '第一阶段离线正文 📝');
        expect(note.isMarkdown, isTrue);
        expect(await database.pendingNoteIds(account), contains(note.noteId));
        expect((await repo.savedAccounts()).single.cacheKey, account);
        expect(client.requests, 0);

        client.offline = false;
        await repo.synchronize(session);
        expect(await database.pendingNoteIds(account), isEmpty);
        final remote = await api.getConflictSnapshot(
          server: session.account.server,
          token: session.token,
          noteId: note.noteId,
        );
        expect(remote.note.content, note.content);
        expect(remote.note.userId, session.account.userId);
        client.offline = true;
        final beforeLogout = client.requests;
        final unsynced = await database.createLocalNote(
          account: session.account,
          notebookId: fixture['notebook'] as String,
          isMarkdown: false,
          title: '保留未同步修改 $run',
          content: '<p>退出后保留</p>',
        );
        await expectLater(repo.logout(session), throwsStateError);
        expect(await repo.restore(), isNotNull);
        await repo.logout(session, discardSessionWithPendingChanges: true);
        expect(await repo.restore(), isNull);
        expect(await sessions.read(account), isNull);
        expect(
          await database.pendingNoteIds(account),
          contains(unsynced.noteId),
        );
        expect(client.requests, beforeLogout);
        client.offline = false;
        final relogin = await repo.beginLogin(
          serverAddress: serverAddress,
          identity: 'admin',
          password: 'gemsnote',
        );
        expect(relogin.hasCache, isTrue);
        final reentered = await repo.completeLogin(relogin, resetCache: false);
        expect(
          (await database.searchableNote(account, unsynced.noteId))!.content,
          '<p>退出后保留</p>',
        );
        await repo.synchronize(reentered);
        expect(await database.pendingNoteIds(account), isEmpty);
        final saved = await api.getConflictSnapshot(
          server: reentered.account.server,
          token: reentered.token,
          noteId: unsynced.noteId,
        );
        expect(saved.note.content, '<p>退出后保留</p>');
        expect(saved.note.isMarkdown, isFalse);
        await repo.logout(reentered);
        expect(await sessions.read(account), isNull);
        await api.logout(server: session.account.server, token: session.token);
        await api.logout(
          server: reentered.account.server,
          token: reentered.token,
        );
      }
      completed = true;
    } finally {
      client.close();
      await database.raw.close();
      if (completed && phase == 'resume') {
        await directory.delete(recursive: true);
        expect(await directory.exists(), isFalse);
      }
    }
  });
}
