import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/data/database/app_database.dart';
import 'package:gemsnote/data/database/attachment_outbox.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/note_image_picker.dart';
import 'package:gemsnote/sync/sync_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'attachment_upload_repository_test.dart'
    show UploadApi, original, noteId, fileId;
import 'cached_login_test.dart' show MemorySessions;

class ReceiptApi extends UploadApi {
  String digest = '';
  bool mismatch = false;
  int queries = 0, cleanups = 0;
  bool loseCleanupResponse = false;
  @override
  Future<
    ({
      String fileId,
      String noteId,
      String digest,
      String state,
      bool canCleanup,
    })
  >
  imageUploadStatus({
    required Uri server,
    required String token,
    required String uploadId,
  }) async {
    queries++;
    return (
      fileId: fileId,
      noteId: noteId,
      digest: mismatch ? 'wrong' : digest,
      state: 'pending',
      canCleanup: true,
    );
  }

  @override
  Future<void> cleanupImageUpload({
    required Uri server,
    required String token,
    required String fileId,
  }) async {
    cleanups++;
    if (loseCleanupResponse) throw StateError('response lost');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late AuthRepository repo;
  late ReceiptApi api;
  late AttachmentOutbox outbox;
  late NoteImageUpload image;
  final session = StoredSession(
    account: Account(
      userId: 'u',
      server: Uri.parse('https://example.test'),
      username: 'u',
      email: '',
      logo: '',
      apiVersion: '1.1.0',
    ),
    token: 't',
  );
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.open(databasePath: inMemoryDatabasePath);
    await db.replaceSnapshot(
      account: session.account,
      notebooks: [],
      notes: [original],
      tags: [],
      lastSyncUsn: 5,
    );
    api = ReceiptApi();
    repo = AuthRepository(api, db, MemorySessions(), SyncCoordinator(api, db));
    outbox = AttachmentOutbox(db.raw, session.account);
    image = await NoteImageUpload.normalize(
      File('assets/images/gemsnote_s.png').readAsBytesSync(),
    );
    api.digest = sha256.convert(image.bytes).toString();
  });
  tearDown(() => db.raw.close());

  test(
    'lost cleanup response freezes insertion until cleanup is confirmed',
    () async {
      final id = await repo.stageNoteImage(session, noteId, image);
      await outbox.markSending(id);
      await outbox.confirm(id, fileId);
      api.loseCleanupResponse = true;
      await expectLater(
        repo.cleanupStagedImageUpload(session, id),
        throwsStateError,
      );
      expect((await outbox.list()).single.state, 'cleaning');
      await expectLater(repo.insertStagedImage(session, id), throwsStateError);
      api.loseCleanupResponse = false;
      await repo.cleanupStagedImageUpload(session, id);
      expect((await outbox.list()).single.state, 'cleaned');
      expect((await outbox.file(id)).bytes, image.bytes);
    },
  );

  test('lost upload response recovers by receipt without reupload; cleanup keeps original', () async {
    final id = await repo.stageNoteImage(session, noteId, image);
    await outbox.markSending(id);
    await repo.recoverStagedImageUpload(session, id);
    expect(api.uploads, 0);
    expect((await outbox.list()).single.remoteId, fileId);
    await repo.cleanupStagedImageUpload(session, id);
    expect(api.cleanups, 1);
    expect((await outbox.list()).single.state, 'cleaned');
    expect((await outbox.file(id)).bytes, image.bytes);
  });

  test(
    'mismatched receipt preserves uncertain original and cannot clean',
    () async {
      final id = await repo.stageNoteImage(session, noteId, image);
      await outbox.markSending(id);
      api.mismatch = true;
      await expectLater(
        repo.recoverStagedImageUpload(session, id),
        throwsStateError,
      );
      expect((await outbox.list()).single.state, 'uncertain');
      await expectLater(
        repo.cleanupStagedImageUpload(session, id),
        throwsStateError,
      );
      expect(api.cleanups, 0);
    },
  );

  test('local unsynced references block server cleanup', () async {
    final id = await repo.stageNoteImage(session, noteId, image);
    await outbox.markSending(id);
    await outbox.confirm(id, fileId);
    await db.saveEditedText(
      session.account.cacheKey,
      noteId,
      'title',
      '![img](/api2/file/getImage?fileId=$fileId)',
    );
    await expectLater(
      repo.cleanupStagedImageUpload(session, id),
      throwsStateError,
    );
    expect(api.cleanups, 0);
    expect((await outbox.list()).single.state, 'uploaded');
  });
}
