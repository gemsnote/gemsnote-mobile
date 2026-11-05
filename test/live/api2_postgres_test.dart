import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/session/session_store.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/services/note_image_picker.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fixture_session.dart';

/// Opt-in destructive test: use only a disposable, loopback server/database.
/// No credentials or response bodies are written to test output.
class _Api2OnlyClient extends http.BaseClient {
  final _inner = http.Client();
  final paths = <String>[];
  bool loseNextCreateResponse = false;
  bool loseNextNotebookResponse = false;
  bool offline = false;
  String? copyContentType;
  int? copyStatus;
  String? copyRedirectPath;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host != '127.0.0.1' ||
        request.url.port != 19090 ||
        !request.url.path.startsWith('/api2/')) {
      throw StateError('Test attempted a request outside its API2 server');
    }
    paths.add(request.url.path);
    if (offline) throw StateError('Offline operation attempted HTTP');
    final response = await _inner.send(request);
    if (loseNextNotebookResponse &&
        request.url.path == '/api2/client/notebook/add') {
      loseNextNotebookResponse = false;
      await response.stream.drain<void>();
      throw const SocketException('Injected lost notebook response');
    }
    if (request.url.path == '/api2/note/copySharedNote') {
      copyContentType = response.headers['content-type'];
      copyStatus = response.statusCode;
      copyRedirectPath = Uri.tryParse(response.headers['location'] ?? '')?.path;
    }
    if (loseNextCreateResponse && request.url.path == '/api2/client/note/add') {
      loseNextCreateResponse = false;
      // The real server committed the request. Lose only its response, so the
      // next sync must reconcile the stable client ID without another note.
      await response.stream.drain<void>();
      throw const SocketException('Injected lost create response');
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

// Host integration tests exercise account keys and repository behavior.
// Native secure-storage persistence is covered by native_api2_session_test.
class _MemorySessions implements SessionStore {
  final tokens = <String, String>{};
  @override
  Future<String?> read(String userId) async => tokens[userId];
  @override
  Future<void> write(String userId, String token) async =>
      tokens[userId] = token;
  @override
  Future<void> delete(String userId) async => tokens.remove(userId);
}

void main() {
  final enabled = Platform.environment['GEMSNOTE_DISPOSABLE_API2'] == '1';
  setUpAll(() {
    if (!enabled) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
    'real API2 groups accept usernames and email with ownership and duplicate checks',
    () async {
      final client = _Api2OnlyClient();
      addTearDown(client.close);
      final api = Api2Client(httpClient: client);
      final server = Uri.parse('http://127.0.0.1:19090/');
      final fixture = FixtureSession(client, server);
      await fixture.login('admin', 'gemsnote');
      // A hex-only username must not be interpreted as the target user's ID.
      final name = DateTime.now().microsecondsSinceEpoch
          .toRadixString(16)
          .padLeft(24, 'a');
      final email = 'group-$name@example.test';
      final created = await fixture.request('/api2/web/adminRegister', {
        'username': name,
        'email': email,
      });
      expect(created['Ok'], true);
      final userId = created['UserId'] as String;
      expect(userId, isNot(name));
      await fixture.request('/api2/web/adminResetPwd', {
        'userId': userId,
        'pwd': 'Group-test-Password12!',
      });
      final owner = await api.login(
        server: server,
        identity: 'admin',
        password: 'gemsnote',
      );
      final reader = await api.login(
        server: server,
        identity: name,
        password: 'Group-test-Password12!',
      );
      final title = 'Group $name';
      await api.createGroup(server: server, token: owner.token, title: title);
      final group = (await api.groups(
        server: server,
        token: owner.token,
      )).singleWhere((g) => g.title == title);
      await api.addGroupMember(
        server: server,
        token: owner.token,
        groupId: group.groupId,
        identity: '  ${name.toUpperCase()}  ',
      );
      var loaded = (await api.groups(
        server: server,
        token: owner.token,
      )).singleWhere((g) => g.groupId == group.groupId);
      expect(loaded.members.single.userId, userId);
      await expectLater(
        api.addGroupMember(
          server: server,
          token: owner.token,
          groupId: group.groupId,
          identity: email.toUpperCase(),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'duplicate',
            'userExistsInGroup',
          ),
        ),
      );
      await expectLater(
        api.addGroupMember(
          server: server,
          token: reader.token,
          groupId: group.groupId,
          identity: 'admin',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'ownership',
            'forbiddenNotMyGroup',
          ),
        ),
      );
      await expectLater(
        api.addGroupMember(
          server: server,
          token: owner.token,
          groupId: group.groupId,
          identity: 'missing-$name',
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'missing', 'userNotExists'),
        ),
      );
      await expectLater(
        api.addGroupMember(
          server: server,
          token: owner.token,
          groupId: group.groupId,
          identity: '   ',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'empty identity',
            'userNotExists',
          ),
        ),
      );
      await api.removeGroupMember(
        server: server,
        token: owner.token,
        groupId: group.groupId,
        userId: userId,
      );
      await api.addGroupMember(
        server: server,
        token: owner.token,
        groupId: group.groupId,
        identity: email.toUpperCase(),
      );
      await api.renameGroup(
        server: server,
        token: owner.token,
        groupId: group.groupId,
        title: '$title renamed',
      );
      loaded = (await api.groups(
        server: server,
        token: owner.token,
      )).singleWhere((g) => g.groupId == group.groupId);
      expect(loaded.members.single.userId, userId);
      expect(loaded.title, '$title renamed');
      await api.deleteGroup(
        server: server,
        token: owner.token,
        groupId: group.groupId,
      );
      expect(
        (await api.groups(
          server: server,
          token: owner.token,
        )).any((g) => g.groupId == group.groupId),
        false,
      );
    },
    skip: enabled
        ? false
        : 'Requires an explicitly disposable local API2 server',
  );

  test(
    'real API2 creation receipts recover notebooks and safely clean unused images',
    () async {
      final client = _Api2OnlyClient();
      addTearDown(client.close);
      final api = Api2Client(httpClient: client);
      final server = Uri.parse('http://127.0.0.1:19090/');
      final login = await api.login(
        server: server,
        identity: 'admin',
        password: 'gemsnote',
      );
      expect(login.account.supportsUploadReceipts, true);
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      await db.replaceSnapshot(
        account: login.account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 0,
      );
      final sync = SyncCoordinator(api, db);
      final repo = AuthRepository(api, db, _MemorySessions(), sync);
      final session = StoredSession(account: login.account, token: login.token);
      final book = await repo.createOfflineNotebook(
        session,
        'Receipt test',
        '',
      );
      client.loseNextNotebookResponse = true;
      await expectLater(
        sync.uploadPending(account: login.account, token: login.token),
        throwsA(anything),
      );
      await sync.uploadPending(account: login.account, token: login.token);
      final books = await api.getNotebooks(
        server: server,
        token: login.token,
        afterUsn: 0,
      );
      expect(
        books.where((item) => item.notebookId == book.notebookId).length,
        1,
      );
      final savedBook = books.singleWhere(
        (item) => item.notebookId == book.notebookId,
      );
      final repeated = await api.saveNotebook(
        server: server,
        token: login.token,
        title: 'A retry must not rename',
        clientNotebookId: book.notebookId,
      );
      expect(repeated.title, 'Receipt test');
      expect(repeated.usn, savedBook.usn);

      final key = DateTime.now().microsecondsSinceEpoch
          .toRadixString(16)
          .padLeft(24, '0');
      final concurrent = await Future.wait(
        List.generate(
          6,
          (_) => api.saveNotebook(
            server: server,
            token: login.token,
            title: 'Concurrent creation',
            clientNotebookId: key,
          ),
        ),
      );
      expect(concurrent.map((book) => book.notebookId).toSet(), {key});
      expect(concurrent.map((book) => book.usn).toSet().length, 1);
      await api.deleteNotebook(
        server: server,
        token: login.token,
        notebook: concurrent.first,
      );
      await expectLater(
        api.saveNotebook(
          server: server,
          token: login.token,
          title: 'Cannot resurrect',
          clientNotebookId: key,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'reason',
            'creationKeyDeleted',
          ),
        ),
      );

      final fixture = FixtureSession(client, server);
      await fixture.login('admin', 'gemsnote');
      addTearDown(fixture.close);
      final email =
          'receipt-${DateTime.now().microsecondsSinceEpoch}@example.test';
      const password = 'disposable-receipt-password';
      expect(
        (await fixture.request('/api2/web/adminRegister', {
          'email': email,
          'pwd': password,
        }))['Ok'],
        true,
      );
      final other = await api.login(
        server: server,
        identity: email,
        password: password,
      );
      await expectLater(
        api.saveNotebook(
          server: server,
          token: other.token,
          title: 'Cannot take ownership',
          clientNotebookId: book.notebookId,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'reason',
            'creationKeyUnavailable',
          ),
        ),
      );

      final local = await db.createLocalNote(
        account: login.account,
        notebookId: book.notebookId,
        isMarkdown: true,
      );
      await sync.uploadPending(account: login.account, token: login.token);
      final image = await NoteImageUpload.normalize(
        File('assets/images/gemsnote_s.png').readAsBytesSync(),
      );
      final uploadId = 'receipt_${DateTime.now().microsecondsSinceEpoch}';
      Future<String> upload(String key) => api.uploadNoteImage(
        server: server,
        token: login.token,
        userId: login.account.userId,
        noteId: local.noteId,
        image: image,
        uploadId: key,
      );
      final ref = await upload(uploadId);
      expect(await upload(uploadId), ref);
      final pending = await api.imageUploadStatus(
        server: server,
        token: login.token,
        uploadId: uploadId,
      );
      expect(pending.canCleanup, true);
      await expectLater(
        api.imageUploadStatus(
          server: server,
          token: other.token,
          uploadId: uploadId,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'reason',
            'uploadNotFound',
          ),
        ),
      );
      await expectLater(
        api.cleanupImageUpload(
          server: server,
          token: other.token,
          fileId: pending.fileId,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'reason',
            'uploadNotFound',
          ),
        ),
      );
      await api.cleanupImageUpload(
        server: server,
        token: login.token,
        fileId: pending.fileId,
      );
      await api.cleanupImageUpload(
        server: server,
        token: login.token,
        fileId: pending.fileId,
      );
      expect(
        (await api.imageUploadStatus(
          server: server,
          token: login.token,
          uploadId: uploadId,
        )).state,
        'deleted',
      );
      await expectLater(upload(uploadId), throwsA(isA<ApiException>()));

      final usedKey = '${uploadId}_used';
      final usedRef = await upload(usedKey);
      var current = (await api.getConflictSnapshot(
        server: server,
        token: login.token,
        noteId: local.noteId,
      )).note;
      await api.updateNote(
        server: server,
        token: login.token,
        note: current.copyWith(content: '![image]($usedRef)'),
      );
      final retained = await api.imageUploadStatus(
        server: server,
        token: login.token,
        uploadId: usedKey,
      );
      expect(retained.state, 'retained');
      await expectLater(
        api.cleanupImageUpload(
          server: server,
          token: login.token,
          fileId: retained.fileId,
        ),
        throwsA(isA<ApiException>()),
      );
      current = (await api.getConflictSnapshot(
        server: server,
        token: login.token,
        noteId: local.noteId,
      )).note;
      await api.updateNote(
        server: server,
        token: login.token,
        note: current.copyWith(content: 'image removed from current body'),
      );
      await expectLater(
        api.cleanupImageUpload(
          server: server,
          token: login.token,
          fileId: retained.fileId,
        ),
        throwsA(isA<ApiException>()),
      );
    },
    skip: enabled
        ? false
        : 'Requires an explicitly disposable local API2 server',
  );
  test(
    'real API2 rejects invalid and revoked bearer tokens',
    () async {
      final client = _Api2OnlyClient();
      addTearDown(client.close);
      final api = Api2Client(httpClient: client);
      final server = Uri.parse('http://127.0.0.1:19090/');
      await expectLater(
        api.userInfo(server: server, token: 'invalid-token'),
        throwsA(isA<ApiException>()),
      );
      final login = await api.login(
        server: server,
        identity: 'admin',
        password: 'gemsnote',
      );
      await api.logout(server: server, token: login.token);
      await expectLater(
        api.userInfo(server: server, token: login.token),
        throwsA(isA<ApiException>()),
      );
    },
    skip: enabled
        ? false
        : 'Requires an explicitly disposable local API2 server',
  );
  test(
    'real API2 account switching isolates offline drafts and credentials',
    () async {
      final client = _Api2OnlyClient();
      addTearDown(client.close);
      final api = Api2Client(httpClient: client);
      final server = Uri.parse('http://127.0.0.1:19090/');
      final admin = FixtureSession(client, server);
      await admin.login('admin', 'gemsnote');
      addTearDown(() async {
        client.offline = false;
        await admin.close();
      });
      final run = DateTime.now().microsecondsSinceEpoch;
      final email = 'mobile-switch-$run@example.test';
      const password = 'temporary-fixture-password';
      expect(
        (await admin.request('/api2/web/adminRegister', {
          'email': email,
          'pwd': password,
        }))['Ok'],
        isTrue,
      );
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      final sessions = _MemorySessions();
      AuthRepository repository() =>
          AuthRepository(api, db, sessions, SyncCoordinator(api, db));
      var repo = repository();
      Future<StoredSession> login(String identity, String secret) async {
        final pending = await repo.beginLogin(
          serverAddress: server.toString(),
          identity: identity,
          password: secret,
        );
        return repo.completeLogin(pending, resetCache: false);
      }

      final first = await login('admin', 'gemsnote');
      final firstBook = await api.saveNotebook(
        server: server,
        token: first.token,
        title: 'Account isolation $run',
      );
      await repo.synchronize(first);
      await repo.setAutoSync(first, true);
      client.offline = true;
      final firstDraft = await db.createLocalNote(
        account: first.account,
        notebookId: firstBook.notebookId,
        isMarkdown: true,
        title: 'Private A $run',
        content: '账号 A 离线正文 📝',
      );
      client.offline = false;
      final second = await login(email, password);
      expect(second.account.cacheKey, isNot(first.account.cacheKey));
      expect(await repo.autoSync(second), isFalse);
      final secondBook = await api.saveNotebook(
        server: server,
        token: second.token,
        title: 'Account isolation $run',
      );
      await repo.synchronize(second);
      client.offline = true;
      final secondDraft = await db.createLocalNote(
        account: second.account,
        notebookId: secondBook.notebookId,
        isMarkdown: false,
        title: 'Private B $run',
        content: '<p>账号 B 离线正文</p>',
      );
      final beforeSwitch = client.paths.length;
      repo = repository();
      expect((await repo.restore())!.account.cacheKey, second.account.cacheKey);
      final restoredFirst = await repo.switchAccount(first.account.cacheKey);
      expect(restoredFirst.token == first.token, isTrue);
      expect(await repo.autoSync(restoredFirst), isTrue);
      expect(
        await db.searchableNote(first.account.cacheKey, secondDraft.noteId),
        isNull,
      );
      expect(
        await db.searchableNote(second.account.cacheKey, firstDraft.noteId),
        isNull,
      );
      expect(
        await db.pendingNoteIds(first.account.cacheKey),
        contains(firstDraft.noteId),
      );
      expect(
        await db.pendingNoteIds(second.account.cacheKey),
        contains(secondDraft.noteId),
      );
      expect(client.paths.length, beforeSwitch);

      client.offline = false;
      await repo.synchronize(restoredFirst);
      expect(await db.pendingNoteIds(first.account.cacheKey), isEmpty);
      expect(
        await db.pendingNoteIds(second.account.cacheKey),
        contains(secondDraft.noteId),
      );
      final remoteFirst = await api.getConflictSnapshot(
        server: server,
        token: first.token,
        noteId: firstDraft.noteId,
      );
      expect(remoteFirst.note.content, firstDraft.content);
      expect(remoteFirst.note.userId, first.account.userId);
      await expectLater(
        api.getConflictSnapshot(
          server: server,
          token: second.token,
          noteId: firstDraft.noteId,
        ),
        throwsA(isA<ApiException>()),
      );
      final restoredSecond = await repo.switchAccount(second.account.cacheKey);
      await repo.synchronize(restoredSecond);
      expect(await db.pendingNoteIds(second.account.cacheKey), isEmpty);
      final remoteSecond = await api.getConflictSnapshot(
        server: server,
        token: second.token,
        noteId: secondDraft.noteId,
      );
      expect(remoteSecond.note.content, secondDraft.content);
      expect(remoteSecond.note.userId, second.account.userId);
      await expectLater(
        api.getConflictSnapshot(
          server: server,
          token: first.token,
          noteId: secondDraft.noteId,
        ),
        throwsA(isA<ApiException>()),
      );
      client.offline = true;
      final beforeLogout = client.paths.length;
      await repo.logout(restoredSecond);
      expect(await repo.restore(), isNull);
      expect(await sessions.read(second.account.cacheKey), isNull);
      expect(
        await sessions.read(first.account.cacheKey) == first.token,
        isTrue,
      );
      expect(
        (await repo.savedAccounts()).single.cacheKey,
        first.account.cacheKey,
      );
      expect(
        (await repo.switchAccount(first.account.cacheKey)).token == first.token,
        isTrue,
      );
      expect(client.paths.length, beforeLogout);
      client.offline = false;
      await api.logout(server: server, token: first.token);
      await api.logout(server: server, token: second.token);
    },
    skip: enabled
        ? false
        : 'Requires an explicitly disposable local API2 server',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'real API2 shared note is read-only and an owned copy is independent',
    () async {
      final client = _Api2OnlyClient();
      addTearDown(client.close);
      final api = Api2Client(httpClient: client);
      final server = Uri.parse('http://127.0.0.1:19090/');
      final owner = await api.login(
        server: server,
        identity: 'admin',
        password: 'gemsnote',
      );
      final admin = FixtureSession(client, server);
      await admin.login('admin', 'gemsnote');
      addTearDown(admin.close);
      final run = DateTime.now().microsecondsSinceEpoch;
      final recipientEmail = 'mobile-recipient-$run@example.test';
      const password = 'temporary-fixture-password';
      expect(
        (await admin.request('/api2/web/adminRegister', {
          'email': recipientEmail,
          'pwd': password,
        }))['Ok'],
        isTrue,
      );
      final recipient = await api.login(
        server: server,
        identity: recipientEmail,
        password: password,
      );
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      for (final account in [owner.account, recipient.account]) {
        await db.replaceSnapshot(
          account: account,
          notebooks: [],
          notes: [],
          tags: [],
          lastSyncUsn: 0,
        );
      }
      final ownBook = await api.saveNotebook(
        server: server,
        token: owner.token,
        title: 'Shared source $run',
      );
      final target = await api.saveNotebook(
        server: server,
        token: recipient.token,
        title: 'Owned copies $run',
      );
      final draft = await db.createLocalNote(
        account: owner.account,
        notebookId: ownBook.notebookId,
        isMarkdown: true,
        title: 'Shared immutable source $run',
        content: '# 原作者正文\n共享者只能复制 📝',
      );
      final sync = SyncCoordinator(api, db);
      await sync.synchronize(account: owner.account, token: owner.token);
      final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
      final originalFile = await api.uploadAttachment(
        server: server,
        token: owner.token,
        userId: owner.account.userId,
        noteId: draft.noteId,
        file: AttachmentUpload(name: 'shared-original.bin', bytes: bytes),
      );
      final grant = await admin.request('/api2/share/addShareNote', {
        'noteId': draft.noteId,
        'emails[0]': recipientEmail,
        'perm': '1', // Legacy callers cannot turn a share into write access.
      });
      expect((grant[recipientEmail] as Map)['Ok'], isTrue);
      final shared = (await api.sharedNotes(
        server: server,
        token: recipient.token,
      )).singleWhere((item) => item.note.noteId == draft.noteId);
      expect(
        (await api.sharedContent(
          server: server,
          token: recipient.token,
          shared: shared,
        )).content,
        draft.content,
      );
      final sharedFile = shared.files.singleWhere(
        (f) => f.fileId == originalFile,
      );
      expect(
        await api.sharedFile(
          server: server,
          token: recipient.token,
          shared: shared,
          file: sharedFile,
        ),
        bytes,
      );
      final original = await api.getConflictSnapshot(
        server: server,
        token: owner.token,
        noteId: draft.noteId,
      );
      await expectLater(
        api.updateNote(
          server: server,
          token: recipient.token,
          note: original.note.copyWith(content: 'must not overwrite owner'),
        ),
        throwsA(isA<ApiException>()),
      );
      try {
        await api.copySharedNote(
          server: server,
          token: recipient.token,
          shared: shared,
          notebookId: target.notebookId,
        );
      } finally {
        expect(
          client.copyStatus,
          200,
          reason: 'Token-only copy redirected to ${client.copyRedirectPath}',
        );
        expect(
          client.copyContentType,
          contains('application/json'),
          reason: 'Token-only API2 copy must return JSON, not a login page',
        );
      }
      await sync.synchronize(
        account: recipient.account,
        token: recipient.token,
      );
      final copied = (await db.notes(
        recipient.account.cacheKey,
        notebookId: target.notebookId,
      )).single;
      expect(copied.noteId, isNot(draft.noteId));
      expect(copied.userId, recipient.account.userId);
      expect(copied.content, draft.content);
      final copiedFiles = await api.noteFiles(
        server: server,
        token: recipient.token,
        noteId: copied.noteId,
        userId: recipient.account.userId,
      );
      expect(copiedFiles.single.id, isNot(originalFile));
      expect(
        await api.noteAttachment(
          server: server,
          token: recipient.token,
          noteId: copied.noteId,
          userId: recipient.account.userId,
          file: copiedFiles.single,
        ),
        bytes,
      );
      await db.saveEditedText(
        recipient.account.cacheKey,
        copied.noteId,
        'My edited copy $run',
        '# 修改自己的副本',
      );
      await sync.synchronize(
        account: recipient.account,
        token: recipient.token,
      );
      expect(
        (await api.getConflictSnapshot(
          server: server,
          token: recipient.token,
          noteId: copied.noteId,
        )).note.content,
        '# 修改自己的副本',
      );
      expect(
        (await api.getConflictSnapshot(
          server: server,
          token: owner.token,
          noteId: draft.noteId,
        )).note.content,
        draft.content,
      );
      await admin.revokeNote(draft.noteId, recipient.account.userId);
      await expectLater(
        api.sharedContent(
          server: server,
          token: recipient.token,
          shared: shared,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(
        (await api.getConflictSnapshot(
          server: server,
          token: recipient.token,
          noteId: copied.noteId,
        )).note.content,
        '# 修改自己的副本',
      );
      await api.logout(server: server, token: recipient.token);
      await api.logout(server: server, token: owner.token);
    },
    skip: enabled
        ? false
        : 'Requires an explicitly disposable local API2 server',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'real API2 notebook and tag deletion converge through incremental sync',
    () async {
      final client = _Api2OnlyClient();
      addTearDown(client.close);
      final api = Api2Client(httpClient: client);
      final server = Uri.parse('http://127.0.0.1:19090/');
      final login = await api.login(
        server: server,
        identity: 'admin',
        password: 'gemsnote',
      );
      final account = login.account;
      final token = login.token;
      final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
      addTearDown(db.raw.close);
      await db.replaceSnapshot(
        account: account,
        notebooks: [],
        notes: [],
        tags: [],
        lastSyncUsn: 0,
      );
      final sync = SyncCoordinator(api, db);
      final run = DateTime.now().microsecondsSinceEpoch;
      final parent = await api.saveNotebook(
        server: server,
        token: token,
        title: 'Parent $run',
      );
      final child = await api.saveNotebook(
        server: server,
        token: token,
        title: 'Child $run',
        parentNotebookId: parent.notebookId,
      );
      final renamed = await api.saveNotebook(
        server: server,
        token: token,
        title: '重命名 $run',
        existing: child,
      );
      expect(renamed.parentNotebookId, parent.notebookId);
      await sync.synchronize(account: account, token: token);
      expect(
        (await db.notebooks(account.cacheKey))
            .singleWhere((book) => book.notebookId == child.notebookId)
            .title,
        renamed.title,
      );
      await expectLater(
        api.deleteNotebook(server: server, token: token, notebook: parent),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'reason',
            '笔记本下有子笔记本',
          ),
        ),
      );
      await expectLater(
        api.deleteNotebook(server: server, token: token, notebook: child),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'reason',
            'conflict',
          ),
        ),
      );
      await api.deleteNotebook(server: server, token: token, notebook: renamed);
      await sync.synchronize(account: account, token: token);
      expect(
        (await db.notebooks(account.cacheKey)).map((book) => book.notebookId),
        isNot(contains(child.notebookId)),
      );
      final currentParent = (await db.notebooks(account.cacheKey))
          .singleWhere((book) => book.notebookId == parent.notebookId);
      await api.deleteNotebook(
        server: server,
        token: token,
        notebook: currentParent,
      );
      await sync.synchronize(account: account, token: token);
      expect(
        (await db.notebooks(account.cacheKey)).map((book) => book.notebookId),
        isNot(contains(parent.notebookId)),
      );

      final tag = '临时标签 $run';
      final createdUsn = await api.createTag(
        server: server,
        token: token,
        userId: account.userId,
        name: tag,
      );
      final taggedBook = await api.saveNotebook(
        server: server,
        token: token,
        title: 'Tag references $run',
      );
      await sync.synchronize(account: account, token: token);
      final taggedIds = <bool, String>{};
      for (final trash in [false, true]) {
        final note = await db.createLocalNote(
          account: account,
          notebookId: taggedBook.notebookId,
          isMarkdown: true,
          title: 'Tagged $trash $run',
          content: 'Keep body $trash',
        );
        taggedIds[trash] = note.noteId;
        await db.saveLocalNote(
          account.cacheKey,
          note.copyWith(tags: [tag], isTrash: trash),
        );
      }
      await sync.synchronize(account: account, token: token);
      for (final trash in [false, true]) {
        final note = (await db.notes(
          account.cacheKey,
          trashOnly: trash,
        )).singleWhere((note) => note.noteId == taggedIds[trash]);
        expect(note.tags, [tag]);
      }
      expect(
        await db.tagCounts(account.cacheKey, includeUnused: true),
        contains(tag),
      );
      final checkpoint = await db.lastSyncUsn(account.cacheKey);
      final deletedUsn = await api.deleteTag(
        server: server,
        token: token,
        name: tag,
        usn: createdUsn,
      );
      expect(deletedUsn, greaterThan(checkpoint));
      final changes = await api.getTags(
        server: server,
        token: token,
        afterUsn: checkpoint,
      );
      expect(
        changes.singleWhere((item) => item['Tag'] == tag)['IsDeleted'],
        isTrue,
      );
      await sync.synchronize(account: account, token: token);
      expect(
        await db.tagCounts(account.cacheKey, includeUnused: true),
        isNot(contains(tag)),
      );
      for (final trash in [false, true]) {
        final note = (await db.notes(
          account.cacheKey,
          trashOnly: trash,
        )).singleWhere((note) => note.noteId == taggedIds[trash]);
        expect(note.tags, isEmpty);
        expect(note.content, 'Keep body $trash');
        expect(note.isTrash, trash);
        expect(note.usn, greaterThan(checkpoint));
      }
      expect(
        await db.lastSyncUsn(account.cacheKey),
        greaterThanOrEqualTo(deletedUsn),
      );
      await api.logout(server: server, token: token);
    },
    skip: enabled
        ? false
        : 'Requires an explicitly disposable local API2 server',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  for (final scenario in ['upload', 'lostResponse', 'history']) {
    final restore = scenario == 'history';
    test(
      restore
          ? 'real API2 subsequent edit and complete history restore'
          : 'real API2 two-client sync and binary upload: $scenario',
      () async {
        final client = _Api2OnlyClient();
        addTearDown(client.close);
        final api = Api2Client(httpClient: client);
        final server = Uri.parse('http://127.0.0.1:19090/');
        final login = await api.login(
          server: server,
          identity: 'admin',
          password: 'gemsnote',
        );
        final account = login.account;
        final token = login.token;
        final db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
        addTearDown(db.raw.close);
        final secondDb = await AppDatabase.open(
          databasePath: inMemoryDatabasePath,
        );
        addTearDown(secondDb.raw.close);
        for (final local in [db, secondDb]) {
          await local.replaceSnapshot(
            account: account,
            notebooks: [],
            notes: [],
            tags: [],
            lastSyncUsn: 0,
          );
        }
        final sync = SyncCoordinator(api, db);
        final secondSync = SyncCoordinator(api, secondDb);
        final run = DateTime.now().microsecondsSinceEpoch;
        final notebook = await api.saveNotebook(
          server: server,
          token: token,
          title: 'Mobile live test $run',
        );
        await sync.synchronize(account: account, token: token);
        expect(
          (await db.notebooks(account.cacheKey)).map((n) => n.notebookId),
          contains(notebook.notebookId),
        );
        final draft = await db.createLocalNote(
          account: account,
          notebookId: notebook.notebookId,
          isMarkdown: true,
          title: '离线笔记 $run',
          content: '# 第一版\n中文与 emoji 📝\n',
        );
        expect(
          await db.pendingNoteIds(account.cacheKey),
          contains(draft.noteId),
        );
        if (scenario == 'lostResponse') {
          client.loseNextCreateResponse = true;
          await expectLater(
            sync.synchronize(account: account, token: token),
            throwsA(isA<ApiException>()),
          );
          expect(client.loseNextCreateResponse, isFalse);
          expect(
            await db.pendingNoteIds(account.cacheKey),
            contains(draft.noteId),
          );
          // Verify the remote commit from an independent cache before retrying.
          await secondSync.synchronize(account: account, token: token);
          expect(
            (await secondDb.searchableNote(
              account.cacheKey,
              draft.noteId,
            ))?.content,
            draft.content,
          );
        }
        await sync.synchronize(account: account, token: token);
        expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
        await secondSync.synchronize(account: account, token: token);
        final first = (await secondDb.searchableNote(
          account.cacheKey,
          draft.noteId,
        ))!;
        expect(first.content, draft.content);
        expect(first.isMarkdown, isTrue);
        expect(
          (await secondDb.notes(account.cacheKey))
              .where((note) => note.title == draft.title),
          hasLength(1),
        );

        final bytes = Uint8List.fromList([0, 1, 2, 127, 128, 255]);
        final attachmentId = await api.uploadAttachment(
          server: server,
          token: token,
          userId: account.userId,
          noteId: draft.noteId,
          file: AttachmentUpload(name: '原件.bin', bytes: bytes),
        );
        final files = await api.noteFiles(
          server: server,
          token: token,
          userId: account.userId,
          noteId: draft.noteId,
        );
        final file = files.singleWhere((file) => file.id == attachmentId);
        expect(
          await api.noteAttachment(
            server: server,
            token: token,
            noteId: draft.noteId,
            userId: account.userId,
            file: file,
          ),
          bytes,
        );
        if (!restore) {
          await secondSync.synchronize(account: account, token: token);
          expect(
            (await secondDb.searchableNote(
              account.cacheKey,
              draft.noteId,
            ))!.content,
            draft.content,
          );
          await api.logout(server: server, token: token);
          return;
        }
        await sync.synchronize(account: account, token: token);
        await db.saveEditedText(
          account.cacheKey,
          draft.noteId,
          '第二版 $run',
          '第二版正文',
        );
        await sync.synchronize(account: account, token: token);
        await expectLater(
          api.updateNote(
            server: server,
            token: token,
            note: first.copyWith(content: 'stale writer'),
          ),
          throwsA(isA<ApiException>()),
        );
        final histories = await api.getHistories(
          server: server,
          token: token,
          noteId: draft.noteId,
        );
        final matching = <String>[];
        for (final history in histories.where((h) => h.filesComplete)) {
          final content = await api.getHistoryContent(
            server: server,
            token: token,
            noteId: draft.noteId,
            historyId: history.id,
          );
          if (content == draft.content) matching.add(history.id);
        }
        expect(matching, isNotEmpty);
        final current = (await db.searchableNote(
          account.cacheKey,
          draft.noteId,
        ))!;
        await api.restoreHistorySnapshot(
          server: server,
          token: token,
          noteId: draft.noteId,
          historyId: matching.first,
          usn: current.usn,
        );
        await secondSync.synchronize(account: account, token: token);
        expect(
          (await secondDb.searchableNote(
            account.cacheKey,
            draft.noteId,
          ))!.content,
          draft.content,
        );
        final restoredFiles = await api.noteFiles(
          server: server,
          token: token,
          noteId: draft.noteId,
          userId: account.userId,
        );
        expect(restoredFiles.map((file) => file.id), contains(attachmentId));
        expect(
          await api.noteAttachment(
            server: server,
            token: token,
            noteId: draft.noteId,
            userId: account.userId,
            file: restoredFiles.singleWhere((file) => file.id == attachmentId),
          ),
          bytes,
        );
        expect(client.paths, contains('/api2/note/restoreHistory'));
        await api.logout(server: server, token: token);
      },
      skip: enabled
          ? false
          : 'Requires an explicitly disposable local API2 server',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
