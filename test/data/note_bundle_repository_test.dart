import 'package:gemsnote/core/api/api_exception.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/attachment_outbox.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/attachment_upload.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_bundle.dart';
import 'package:gemsnote/domain/models/note_file.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/note_image_picker.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cached_login_test.dart' show MemorySessions;

class BundleApi extends Api2Client {
  late Note remote;
  List<NoteFile> files = [];
  Map<String, Uint8List> originals = {};
  int calls = 0;
  bool fail = false;
  bool conflict = false, loseCreateResponse = false;
  final created = <String, Note>{};
  int createCalls = 0;
  int imageUploadCalls = 0;
  final updatedIds = <String>[];
  Future<void> Function()? duringDownload;
  Future<void> Function()? duringUpload;
  @override
  Future<Note> updateNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    if (conflict) throw const ApiException('conflict');
    updatedIds.add(note.noteId);
    return note.copyWith(usn: note.usn + 1);
  }

  @override
  Future<Note> addNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    createCalls++;
    final saved = created.putIfAbsent(
      note.noteId,
      () => note.copyWith(usn: 10),
    );
    if (loseCreateResponse) throw StateError('lost response');
    return saved;
  }

  @override
  Future<int> getSyncUsn({required Uri server, required String token}) async =>
      100;
  @override
  Future<String> uploadNoteImage({
    required Uri server,
    required String token,
    required String userId,
    required String noteId,
    required NoteImageUpload image,
    Future<void> Function()? beforeSend,
    String? uploadId,
  }) async {
    await beforeSend?.call();
    imageUploadCalls++;
    return '/api2/file/getImage?fileId=507f1f77bcf86cd799439013';
  }

  @override
  Future<String> uploadAttachment({
    required Uri server,
    required String token,
    required String userId,
    required String noteId,
    required AttachmentUpload file,
    Future<void> Function()? beforeSend,
  }) async {
    await beforeSend?.call();
    remote = remote.copyWith(usn: remote.usn + 1);
    await duringUpload?.call();
    return '507f1f77bcf86cd799439013';
  }

  @override
  Future<({Note note, bool filesConfirmedEmpty})> getConflictSnapshot({
    required Uri server,
    required String token,
    required String noteId,
  }) async {
    calls++;
    if (fail) throw StateError('offline');
    return (
      note: created[noteId] ?? remote,
      filesConfirmedEmpty: files.isEmpty,
    );
  }

  @override
  Future<List<NoteFile>> noteFiles({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
  }) async => files;
  @override
  Future<Uint8List> noteAttachment({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
    required NoteFile file,
  }) async {
    await duringDownload?.call();
    return originals[file.id]!;
  }

  @override
  Future<Uint8List> noteImage({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
    required NoteFile file,
  }) => noteAttachment(
    server: server,
    token: token,
    noteId: noteId,
    userId: userId,
    file: file,
  );
}

void main() {
  const imageId = '507f1f77bcf86cd799439011',
      attachId = '507f1f77bcf86cd799439012',
      newId = '507f1f77bcf86cd799439013';
  final account = Account(
    userId: 'u',
    server: Uri.parse('https://source.test'),
    username: '',
    email: '',
    logo: '',
  );
  final session = StoredSession(account: account, token: 'secret');
  late Directory temp;
  late AppDatabase db;
  late AuthRepository repo;
  late SyncCoordinator sync;
  late BundleApi api;
  late Note source;
  void connect() {
    sync = SyncCoordinator(api, db);
    repo = AuthRepository(api, db, MemorySessions(), sync);
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bundle-repository-');
    db = await AppDatabase.open(databasePath: '${temp.path}/db');
    source = Note.fromJson({
      'NoteId': 'n',
      'NotebookId': 'b',
      'UserId': 'u',
      'Title': 'source',
      'Content':
          '<table data-custom="keep"><tr><td><img src="https://source.test/file/outputImage?fileId=$imageId"><a href="/api2/file/getAttach?fileId=$attachId">file</a></td></tr></table>',
      'Usn': 7,
    });
    await db.replaceSnapshot(
      account: account,
      notebooks: [
        Notebook.fromJson({'NotebookId': 'b', 'Title': 'Book'}),
      ],
      notes: [source],
      tags: [],
      lastSyncUsn: 7,
    );
    api = BundleApi()
      ..remote = source
      ..files = [
        const NoteFile(
          id: imageId,
          title: 'picture.png',
          type: 'png',
          isAttachment: false,
        ),
        const NoteFile(
          id: attachId,
          title: 'original.bin',
          type: 'bin',
          isAttachment: true,
        ),
      ]
      ..originals = {
        imageId: File('assets/images/gemsnote_s.png').readAsBytesSync(),
        attachId: Uint8List.fromList([0, 255, 1, 2]),
      };
    connect();
  });
  tearDown(() async {
    await db.raw.close();
    await temp.delete(recursive: true);
  });

  test('full copy persists exact body and independent originals, preserving source and cursor', () async {
    final copy = await repo.copyNote(session, source, 'b');
    expect(copy.content, source.content);
    expect(copy.usn, 0);
    expect(
      (await repo.pendingAttachments(session, noteId: copy.noteId)),
      hasLength(2),
    );
    expect(await db.lastSyncUsn(account.cacheKey), 7);
    await db.raw.close();
    db = await AppDatabase.open(databasePath: '${temp.path}/db');
    connect();
    final image = await repo.cachedInlineImage(
      session,
      copy.noteId,
      Uri.parse('https://source.test/file/outputImage?fileId=$imageId'),
    );
    expect(image, api.originals[imageId]);
    final original = await db.searchableNote(account.cacheKey, source.noteId);
    expect(original!.content, source.content);
    api.fail = true;
    final copiedAgain = await repo.copyNote(session, copy, 'b');
    expect(copiedAgain.content, copy.content);
    expect(
      await repo.pendingAttachments(session, noteId: copiedAgain.noteId),
      hasLength(2),
    );
  });
  test('offline visual image keeps selected reference and original until upload confirms', () async {
    final image = await NoteImageUpload.normalize(api.originals[imageId]!);
    final reference = await repo.stageVisualImage(
      session,
      source.noteId,
      image,
    );
    expect(
      reference,
      matches(RegExp(r'^/api2/file/getImage\?fileId=[0-9a-f]{24}$')),
    );
    expect(
      await repo.cachedInlineImage(
        session,
        source.noteId,
        Uri.parse(reference),
      ),
      image.bytes,
    );
    final body = '<p>Before <img src="$reference" alt=""> after</p>';
    await db.saveEditedText(account.cacheKey, source.noteId, 'source', body);
    expect(
      await db.hasUnuploadedVisualPlacement(account.cacheKey, source.noteId),
      isTrue,
    );
    final task = (await repo.pendingAttachments(
      session,
      noteId: source.noteId,
    )).single;
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsA(isA<PendingVisualImage>()),
    );
    expect(api.imageUploadCalls, 0);
    await repo.uploadStagedImage(session, task.id);
    final outbox = AttachmentOutbox(db.raw, account);
    await outbox.insertImage(task.id);
    expect(api.imageUploadCalls, 1);
    expect(
      await db.hasUnuploadedVisualPlacement(account.cacheKey, source.noteId),
      isFalse,
    );
    expect(
      (await db.searchableNote(account.cacheKey, source.noteId))!.content,
      body.replaceFirst(reference, '/api2/file/getImage?fileId=$newId'),
    );
    expect(
      await repo.cachedInlineImage(
        session,
        source.noteId,
        Uri.parse('/api2/file/getImage?fileId=$newId'),
      ),
      image.bytes,
    );
    await sync.uploadPending(account: account, token: 'secret');
    expect(api.updatedIds, [source.noteId]);
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
  });
  test(
    'new visual note creates without a temporary image then uploads in place',
    () async {
      final draft = await db.createLocalNote(
        account: account,
        notebookId: 'b',
        isMarkdown: false,
      );
      final image = await NoteImageUpload.normalize(api.originals[imageId]!);
      final reference = await repo.stageVisualImage(
        session,
        draft.noteId,
        image,
      );
      final body = '<p>Before <img src="$reference" alt=""> after</p>';
      await db.saveEditedText(account.cacheKey, draft.noteId, 'draft', body);
      await expectLater(
        sync.uploadPending(account: account, token: 'secret'),
        throwsA(isA<PendingVisualImage>()),
      );
      expect(api.createCalls, 1);
      expect(api.created[draft.noteId]!.content, contains('Before'));
      expect(api.created[draft.noteId]!.content, contains('after'));
      expect(api.created[draft.noteId]!.content, isNot(contains(reference)));
      expect(api.updatedIds, isNot(contains(draft.noteId)));
      expect(
        (await db.searchableNote(account.cacheKey, draft.noteId))!.usn,
        10,
      );
      expect(
        (await db.searchableNote(account.cacheKey, draft.noteId))!.content,
        body,
      );
      final task = (await repo.pendingAttachments(
        session,
        noteId: draft.noteId,
      )).single;
      await repo.uploadStagedImage(session, task.id);
      expect(api.imageUploadCalls, 1);
      await sync.uploadPending(account: account, token: 'secret');
      expect(api.updatedIds, contains(draft.noteId));
      expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
      expect(
        (await db.searchableNote(account.cacheKey, draft.noteId))!.content,
        body.replaceFirst(reference, '/api2/file/getImage?fileId=$newId'),
      );
    },
  );
  test('lost new-note response replays the sanitized first request', () async {
    final draft = await db.createLocalNote(
      account: account,
      notebookId: 'b',
      isMarkdown: false,
    );
    final image = await NoteImageUpload.normalize(api.originals[imageId]!);
    final reference = await repo.stageVisualImage(session, draft.noteId, image);
    await db.saveEditedText(
      account.cacheKey,
      draft.noteId,
      'draft',
      '<p>One <img src="$reference"> two</p>',
    );
    api.loseCreateResponse = true;
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsStateError,
    );
    final firstBody = api.created[draft.noteId]!.content;
    expect(firstBody, isNot(contains(reference)));
    api.loseCreateResponse = false;
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsA(isA<PendingVisualImage>()),
    );
    expect(api.createCalls, 2);
    expect(api.created, hasLength(1));
    expect(api.created[draft.noteId]!.content, firstBody);
    expect((await db.searchableNote(account.cacheKey, draft.noteId))!.usn, 10);
  });
  test('unrecognized visual reference cannot enter new-note request', () async {
    final draft = await db.createLocalNote(
      account: account,
      notebookId: 'b',
      isMarkdown: false,
    );
    final image = await NoteImageUpload.normalize(api.originals[imageId]!);
    final reference = await repo.stageVisualImage(session, draft.noteId, image);
    await db.saveEditedText(
      account.cacheKey,
      draft.noteId,
      'draft',
      '<p>Broken placement: $reference</p>',
    );
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsStateError,
    );
    expect(api.createCalls, 0);
    expect(await db.pendingNoteIds(account.cacheKey), contains(draft.noteId));
  });
  test(
    'remote version change blocks visual upload before sending original',
    () async {
      final image = await NoteImageUpload.normalize(api.originals[imageId]!);
      final reference = await repo.stageVisualImage(
        session,
        source.noteId,
        image,
      );
      await db.saveEditedText(
        account.cacheKey,
        source.noteId,
        'source',
        '<img src="$reference">',
      );
      final task = (await repo.pendingAttachments(
        session,
        noteId: source.noteId,
      )).single;
      api.remote = source.copyWith(usn: 8);
      await expectLater(
        repo.uploadStagedImage(session, task.id),
        throwsStateError,
      );
      expect(api.imageUploadCalls, 0);
      expect(
        (await repo.pendingAttachments(
          session,
          noteId: source.noteId,
        )).single.state,
        'pending',
      );
    },
  );
  test(
    'pending visual original defers only its note while other uploads finish',
    () async {
      final other = source.copyWith(
        noteId: '507f1f77bcf86cd799439014',
        title: 'other',
        content: 'other body',
      );
      await db.mergeChanges(
        account: account,
        notebooks: [],
        notes: [other],
        tags: [],
        lastSyncUsn: 7,
      );
      final image = await NoteImageUpload.normalize(api.originals[imageId]!);
      final reference = await repo.stageVisualImage(
        session,
        source.noteId,
        image,
      );
      await db.saveEditedText(
        account.cacheKey,
        source.noteId,
        'source',
        '<img src="$reference">',
      );
      await db.saveEditedText(
        account.cacheKey,
        other.noteId,
        'other edit',
        other.content,
      );
      await expectLater(
        sync.uploadPending(account: account, token: 'secret'),
        throwsA(isA<PendingVisualImage>()),
      );
      expect(api.updatedIds, [other.noteId]);
      expect(await db.pendingNoteIds(account.cacheKey), {source.noteId});
    },
  );
  test('cross-server import keeps cached images and rebinds confirmed upload in place only once', () async {
    final bundle = await repo.exportBundle(session, source);
    final other = Account(
      userId: 'v',
      server: Uri.parse('https://destination.test'),
      username: '',
      email: '',
      logo: '',
    );
    final otherSession = StoredSession(account: other, token: 'other');
    await db.replaceSnapshot(
      account: other,
      notebooks: [
        Notebook.fromJson({'NotebookId': 'target', 'Title': 'Target'}),
      ],
      notes: [],
      tags: [],
      lastSyncUsn: 0,
    );
    final imported = await repo.importBundle(
      otherSession,
      'target',
      NoteBundle.decode(bundle.encode()),
    );
    expect(imported.userId, 'v');
    expect(
      await repo.cachedInlineImage(
        otherSession,
        imported.noteId,
        Uri.parse('https://source.test/file/outputImage?fileId=$imageId'),
      ),
      api.originals[imageId],
    );
    final outbox = AttachmentOutbox(db.raw, other);
    final tasks = await outbox.list(noteId: imported.noteId);
    final image = tasks.firstWhere((e) => e.isImage);
    await outbox.markSending(image.id);
    await outbox.confirm(image.id, newId);
    await outbox.insertImage(image.id);
    await outbox.insertImage(image.id);
    final current = (await db.searchableNote(other.cacheKey, imported.noteId))!;
    expect(
      current.content,
      source.content.replaceFirst(
        'https://source.test/file/outputImage?fileId=$imageId',
        '/api2/file/getImage?fileId=$newId',
      ),
    );
    expect(
      await repo.cachedInlineImage(
        otherSession,
        imported.noteId,
        Uri.parse('/api2/file/getImage?fileId=$newId'),
      ),
      api.originals[imageId],
    );
    expect(
      await repo.cachedInlineImage(
        session,
        imported.noteId,
        Uri.parse('https://source.test/file/outputImage?fileId=$imageId'),
      ),
      isNull,
    );
    final attachment = tasks.firstWhere((e) => !e.isImage);
    await outbox.markSending(attachment.id);
    await outbox.confirm(attachment.id, imageId);
    await outbox.insertImage(attachment.id);
    final rebound = (await db.searchableNote(
      other.cacheKey,
      imported.noteId,
    ))!.content;
    expect(
      rebound,
      current.content.replaceFirst(
        'getAttach?fileId=$attachId',
        'getAttach?fileId=$imageId',
      ),
    );
  });
  test(
    'changed local content during downloads aborts without a partial copy',
    () async {
      api.duringDownload = () =>
          db.saveEditedText(account.cacheKey, source.noteId, 'new', 'new body');
      await expectLater(repo.copyNote(session, source, 'b'), throwsStateError);
      expect(await db.notes(account.cacheKey), hasLength(1));
      expect(await repo.pendingAttachments(session), isEmpty);
    },
  );
  test(
    'changed remote version during downloads aborts without a partial copy',
    () async {
      api.duringDownload = () async {
        api.remote = source.copyWith(usn: 8);
      };
      await expectLater(repo.copyNote(session, source, 'b'), throwsStateError);
      expect(await db.notes(account.cacheKey), hasLength(1));
    },
  );
  test(
    'concurrent staged resource addition aborts without silently omitting it',
    () async {
      api.duringDownload = () async {
        await repo.stageAttachment(
          session,
          source.noteId,
          AttachmentUpload(name: 'later', bytes: Uint8List(1)),
        );
      };
      await expectLater(repo.copyNote(session, source, 'b'), throwsStateError);
      expect(await db.notes(account.cacheKey), hasLength(1));
    },
  );
  test(
    'resource staging failure rolls back imported note and all originals',
    () async {
      final bundle = await repo.exportBundle(session, source);
      await db.raw.execute(
        "CREATE TRIGGER fail_bundle BEFORE INSERT ON resource_bindings BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );
      await expectLater(
        repo.importBundle(session, 'b', bundle),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.notes(account.cacheKey), hasLength(1));
      expect(await repo.pendingAttachments(session), isEmpty);
    },
  );
  test(
    'missing own body image is refused instead of producing a broken copy',
    () async {
      api.files = [];
      await expectLater(repo.copyNote(session, source, 'b'), throwsStateError);
      expect(await db.notes(account.cacheKey), hasLength(1));
    },
  );
  test(
    'schema 17 upgrade retains note and creates reference bindings',
    () async {
      await db.raw.execute('DROP TABLE resource_bindings');
      await db.raw.setVersion(17);
      await db.raw.close();
      db = await AppDatabase.open(databasePath: '${temp.path}/db');
      connect();
      expect(await db.raw.query('resource_bindings'), isEmpty);
      expect((await db.notes(account.cacheKey)).single.content, source.content);
      expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
    },
  );
  test('schema 18 upgrade adds local placement marker', () async {
    await db.raw.execute('DROP TABLE resource_bindings');
    await db.raw.execute('''CREATE TABLE resource_bindings (
      task_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, origin TEXT NOT NULL,
      FOREIGN KEY(task_id) REFERENCES attachment_outbox(id) ON DELETE CASCADE
    )''');
    await db.raw.setVersion(18);
    await db.raw.close();
    db = await AppDatabase.open(databasePath: '${temp.path}/db');
    connect();
    final columns = await db.raw.rawQuery(
      'PRAGMA table_info(resource_bindings)',
    );
    expect(columns.map((c) => c['name']), contains('local_placement'));
    expect(await db.raw.getVersion(), AppDatabase.schemaVersion);
  });
  test('upload confirmation adopts attachment USN before rebinding and preserves intervening local edits', () async {
    final bundle = await repo.exportBundle(session, source);
    final imported = await repo.importBundle(session, 'b', bundle);
    api.remote = imported.copyWith(usn: 10);
    await db.markNoteUploaded(account.cacheKey, imported, api.remote);
    final task = (await repo.pendingAttachments(
      session,
      noteId: imported.noteId,
    )).firstWhere((r) => !r.isImage);
    api.duringUpload = () => db.saveEditedText(
      account.cacheKey,
      imported.noteId,
      'later',
      '${imported.content} later',
    );
    expect(await repo.uploadStagedAttachment(session, task.id), true);
    final current = (await db.searchableNote(
      account.cacheKey,
      imported.noteId,
    ))!;
    expect(current.usn, 11);
    expect(current.title, 'later');
    expect(
      current.content,
      '${source.content.replaceFirst('getAttach?fileId=$attachId', 'getAttach?fileId=$newId')} later',
    );
    expect(
      await db.pendingNoteIds(account.cacheKey),
      contains(imported.noteId),
    );
    expect(
      (await repo.pendingAttachments(
        session,
        noteId: imported.noteId,
      )).firstWhere((r) => r.id == task.id).state,
      'inserted',
    );
  });
  test(
    'resource list changes at unchanged note USN cannot yield a mixed bundle',
    () async {
      api.duringDownload = () async {
        api.files = [api.files.last];
      };
      await expectLater(repo.exportBundle(session, source), throwsStateError);
      expect(await db.notes(account.cacheKey), hasLength(1));
    },
  );
  test(
    'inconsistent server file list aborts without deleting cached originals',
    () async {
      await db.replaceNoteFiles(account.cacheKey, source.noteId, api.files);
      final cached = (await db.cachedNoteFiles(
        account.cacheKey,
        source.noteId,
      )).firstWhere((f) => f.id == attachId);
      await db.cacheNoteAttachment(
        account.cacheKey,
        source.noteId,
        cached,
        api.originals[attachId]!,
      );
      api.files = [];
      await expectLater(repo.exportBundle(session, source), throwsStateError);
      expect(
        await db.cachedNoteAttachment(account.cacheKey, source.noteId, cached),
        api.originals[attachId],
      );
      expect(await db.notes(account.cacheKey), hasLength(1));
    },
  );
  Future<void> prepareConflict() async {
    await db.saveEditedText(
      account.cacheKey,
      source.noteId,
      'local',
      '${source.content}<p>my edit</p>',
    );
    api.remote = source.copyWith(
      usn: 8,
      title: 'remote',
      content: '${source.content}<p>other edit</p>',
    );
    api.conflict = true;
  }

  test('sync creates one independent resource-complete copy and adopts remote source', () async {
    await prepareConflict();
    await sync.uploadPending(account: account, token: 'secret');
    final notes = await db.notes(account.cacheKey);
    expect(notes, hasLength(2));
    final copied = notes.singleWhere((n) => n.noteId != source.noteId);
    expect(copied.content, contains('my edit'));
    expect(copied.content, contains('<table data-custom="keep">'));
    expect(copied.usn, 10);
    expect(
      notes.singleWhere((n) => n.noteId == source.noteId).content,
      contains('other edit'),
    );
    expect(
      (await repo.pendingAttachments(session, noteId: copied.noteId)),
      hasLength(2),
    );
    expect(
      await repo.cachedInlineImage(
        session,
        copied.noteId,
        Uri.parse('https://source.test/file/outputImage?fileId=$imageId'),
      ),
      api.originals[imageId],
    );
    expect(await db.lastSyncUsn(account.cacheKey), 7);
    expect(api.createCalls, 1);
  });
  test('lost copy creation response replays one ID without making another conflict copy', () async {
    await prepareConflict();
    api.loseCreateResponse = true;
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsStateError,
    );
    final notes = await db.notes(account.cacheKey);
    expect(notes, hasLength(2));
    final copy = notes.singleWhere((n) => n.noteId != source.noteId);
    expect(copy.usn, 0);
    expect(
      (await repo.pendingAttachments(session, noteId: copy.noteId)),
      hasLength(2),
    );
    api.loseCreateResponse = false;
    await sync.uploadPending(account: account, token: 'secret');
    expect((await db.notes(account.cacheKey)), hasLength(2));
    expect(
      (await db.notes(account.cacheKey))
          .singleWhere((n) => n.noteId == copy.noteId)
          .usn,
      10,
    );
    expect(api.created.length, 1);
    expect(await db.pendingNoteIds(account.cacheKey), isEmpty);
  });
  test('resource staging failure rolls back conflict resolution and retains dirty source', () async {
    await prepareConflict();
    await db.raw.execute(
      "CREATE TRIGGER fail_conflict_bundle BEFORE INSERT ON resource_bindings BEGIN SELECT RAISE(ABORT, 'disk full'); END",
    );
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsA(isA<DatabaseException>()),
    );
    final notes = await db.notes(account.cacheKey);
    expect(notes, hasLength(1));
    expect(notes.single.content, contains('my edit'));
    expect(notes.single.usn, 7);
    expect(await repo.pendingAttachments(session), isEmpty);
  });
  test(
    'missing old body resource leaves original dirty and creates no copy',
    () async {
      await prepareConflict();
      api.files = [];
      await expectLater(
        sync.uploadPending(account: account, token: 'secret'),
        throwsStateError,
      );
      expect(
        (await db.notes(account.cacheKey)).single.content,
        contains('my edit'),
      );
      expect(api.createCalls, 0);
    },
  );
  test(
    'remote deletion preserves local edit and cached originals in a live copy',
    () async {
      await prepareConflict();
      await db.replaceNoteFiles(account.cacheKey, source.noteId, api.files);
      for (final file in await db.cachedNoteFiles(
        account.cacheKey,
        source.noteId,
      )) {
        if (file.isAttachment) {
          await db.cacheNoteAttachment(
            account.cacheKey,
            source.noteId,
            file,
            api.originals[file.id]!,
          );
        } else {
          await db.cacheNoteImage(
            account.cacheKey,
            source.noteId,
            file,
            api.originals[file.id]!,
          );
        }
      }
      api.remote = api.remote.copyWith(isDeleted: true, content: '');
      api.files = [];
      await sync.uploadPending(account: account, token: 'secret');
      final notes = await db.notes(account.cacheKey);
      expect(notes, hasLength(1));
      final copy = notes.single;
      expect(copy.noteId, isNot(source.noteId));
      expect(copy.isTrash, isFalse);
      expect(copy.content, contains('my edit'));
      expect(copy.usn, 10);
      expect(
        await repo.pendingAttachments(session, noteId: copy.noteId),
        hasLength(2),
      );
      expect(
        await repo.cachedInlineImage(
          session,
          copy.noteId,
          Uri.parse('https://source.test/file/outputImage?fileId=$imageId'),
        ),
        api.originals[imageId],
      );
      expect(await db.lastSyncUsn(account.cacheKey), 7);
    },
  );
  test(
    'remote deletion with an uncached original retains the dirty local note',
    () async {
      await prepareConflict();
      await db.replaceNoteFiles(account.cacheKey, source.noteId, api.files);
      api.remote = api.remote.copyWith(isDeleted: true, content: '');
      api.files = [];
      await expectLater(
        sync.uploadPending(account: account, token: 'secret'),
        throwsStateError,
      );
      expect((await db.notes(account.cacheKey)).single.noteId, source.noteId);
      expect(
        (await db.dirtyNotes(account.cacheKey)).single.content,
        contains('my edit'),
      );
      expect(api.createCalls, 0);
    },
  );
  test('deleted note with an unlisted attachment link stays dirty', () async {
    await prepareConflict();
    await db.saveEditedText(
      account.cacheKey,
      source.noteId,
      'local',
      '<p><a href="/api2/file/getAttach?fileId=$attachId">only attachment</a></p>',
    );
    api.remote = api.remote.copyWith(isDeleted: true, content: '');
    api.files = [];
    await expectLater(
      sync.uploadPending(account: account, token: 'secret'),
      throwsStateError,
    );
    expect(
      (await db.dirtyNotes(account.cacheKey)).single.noteId,
      source.noteId,
    );
    expect(api.createCalls, 0);
  });
}
