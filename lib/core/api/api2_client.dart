import '../../domain/models/user_group.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;

import '../../domain/models/account.dart';
import '../../services/note_image_picker.dart';
import '../../domain/models/attachment_upload.dart';
import '../../domain/models/note.dart';
import '../../domain/models/body_image_references.dart';
import '../../domain/models/note_file.dart';
import '../../domain/models/note_history.dart';
import '../../domain/models/notebook.dart';
import '../../domain/models/shared_note.dart';
import '../../domain/models/shared_file.dart';
import '../../domain/models/sharing_navigation.dart';
import 'api_exception.dart';
import '../async/cancellation.dart';

class LoginResult {
  const LoginResult({
    required this.token,
    required this.account,
    required this.serverVersion,
    required this.minimumClientVersion,
  });

  final String token;
  final Account account;
  final String serverVersion;
  final String minimumClientVersion;
}

class Api2Client {
  Api2Client({
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
    this.noteContentTimeout = const Duration(minutes: 5),
  }) : _http = httpClient ?? http.Client();

  static const clientVersion = '1.0.0';
  static const syncNotePageSize = 10;
  final http.Client _http;
  final Duration requestTimeout;
  final Duration noteContentTimeout;

  http.AbortableRequest _newRequest(
    String method,
    Uri uri, {
    Future<void>? abort,
  }) => http.AbortableRequest(
    method,
    uri,
    abortTrigger: abort == null
        ? Cancellation.current?.whenCancelled
        : Cancellation.current == null
        ? abort
        : Future.any([abort, Cancellation.current!.whenCancelled]),
  );
  http.AbortableMultipartRequest _multipart(String method, Uri uri) =>
      http.AbortableMultipartRequest(
        method,
        uri,
        abortTrigger: Cancellation.current?.whenCancelled,
      );
  Future<T> _wait<T>(Future<T> work) =>
      Cancellation.current?.bind(work) ?? work;
  Future<http.StreamedResponse> _send(http.BaseRequest request) {
    Cancellation.current?.check();
    return _wait(_http.send(request));
  }

  Future<http.Response> _readResponse(http.StreamedResponse response) =>
      _wait(http.Response.fromStream(response));

  Future<List<UserGroup>> groups({
    required Uri server,
    required String token,
  }) async {
    final rows = await _requestList(
      server: server,
      path: '/api2/groups',
      token: token,
    );
    try {
      return rows.map(UserGroup.fromJson).toList();
    } on Object {
      throw const ApiException('invalidResponse');
    }
  }

  Future<void> _groupAction(
    Uri server,
    String token,
    String action,
    Map<String, String> fields,
  ) async {
    final result = await _requestFormJson(
      server: server,
      token: token,
      path: '/api2/member/group/$action',
      fields: fields,
    );
    if (result['Ok'] != true) throw const ApiException('invalidResponse');
  }

  Future<void> createGroup({
    required Uri server,
    required String token,
    required String title,
  }) => _groupAction(server, token, 'addGroup', {'title': title});
  Future<void> renameGroup({
    required Uri server,
    required String token,
    required String groupId,
    required String title,
  }) => _groupAction(server, token, 'updateGroupTitle', {
    'groupId': groupId,
    'title': title,
  });
  Future<void> deleteGroup({
    required Uri server,
    required String token,
    required String groupId,
  }) => _groupAction(server, token, 'deleteGroup', {'groupId': groupId});
  Future<void> addGroupMember({
    required Uri server,
    required String token,
    required String groupId,
    required String identity,
  }) => _groupAction(server, token, 'addUser', {
    'groupId': groupId,
    'email': identity.trim(),
  });
  Future<void> removeGroupMember({
    required Uri server,
    required String token,
    required String groupId,
    required String userId,
  }) => _groupAction(server, token, 'deleteUser', {
    'groupId': groupId,
    'userId': userId,
  });

  Future<void> updateUsername({
    required Uri server,
    required String token,
    required String username,
  }) => _tokenFormAction(
    server: server,
    token: token,
    path: '/api2/user/updateUsername',
    fields: {'username': username},
  );

  Future<Map<String, Object?>> queueVerification({
    required Uri server,
    required String token,
    bool current = false,
    String email = '',
    String password = '',
    required String language,
  }) async {
    final result = await _requestFormJson(
      server: server,
      path: '/api2/web/emailChange',
      token: token,
      language: language,
      fields: current ? {'current': 'true'} : {'email': email, 'pwd': password},
    );
    if (result['TaskId'] is! String || (result['TaskId'] as String).isEmpty) {
      throw const ApiException('invalidResponse');
    }
    return result;
  }

  Future<Map<String, Object?>> emailStatus({
    required Uri server,
    required String token,
    required String taskId,
  }) async {
    final result = await _requestFormJson(
      server: server,
      path: '/api2/user/emailStatus',
      token: token,
      fields: {'taskId': taskId},
    );
    if (!{'queued', 'sending', 'sent', 'failed'}.contains(result['State'])) {
      throw const ApiException('invalidResponse');
    }
    return result;
  }

  Future<SharingNavigation> sharingNavigation({
    required Uri server,
    required String token,
    required String userId,
  }) async {
    final result = await _requestJson(
      server: server,
      path: '/api2/bootstrap',
      method: 'GET',
      token: token,
    );
    if (result['User'] is! Map || (result['User'] as Map)['UserId'] != userId) {
      throw const ApiException('accountMismatch');
    }
    return SharingNavigation.fromJson(_map(result['Sharing']));
  }

  Future<void> moveSharedNote({
    required Uri server,
    required String token,
    required String noteId,
    required String notebookId,
  }) async {
    final result = await _requestJson(
      server: server,
      path: '/api2/shared/move',
      method: 'POST',
      token: token,
      body: {'noteId': noteId, 'notebookId': notebookId},
    );
    if (result['Ok'] != true) throw const ApiException('moveFailed');
  }

  Future<List<Map<String, Object?>>> shareMembers({
    required Uri server,
    required String token,
    required String noteId,
  }) async {
    final result = await _requestFormJson(
      server: server,
      path: '/api2/web/shareMembers',
      token: token,
      fields: {'noteId': noteId},
    );
    return (result['Users'] as List? ?? []).map((item) => _map(item)).toList();
  }

  Future<void> shareNote({
    required Uri server,
    required String token,
    required String noteId,
    required String email,
  }) async {
    final result = await _requestFormJson(
      server: server,
      path: '/api2/share/addShareNote',
      token: token,
      fields: {'noteId': noteId, 'emails[0]': email, 'perm': '0'},
    );
    final status = _map(result[email]);
    if (status['Ok'] != true) {
      throw ApiException(status['Msg']?.toString() ?? 'shareFailed');
    }
  }

  Future<void> revokeNoteShare({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
  }) async {
    final result = await _requestFormValue(
      server: server,
      path: '/api2/share/deleteShareNote',
      token: token,
      fields: {'noteId': noteId, 'toUserId': userId},
    );
    if (result != true) throw const ApiException('shareFailed');
  }

  Future<void> requestEmailChange({
    required Uri server,
    required String token,
    required String userId,
    required String identity,
    required String password,
    required String email,
  }) => _tokenFormAction(
    server: server,
    token: token,
    path: '/api2/web/emailChange',
    fields: {'email': email, 'pwd': password},
  );

  Future<void> changePassword({
    required Uri server,
    required String token,
    required String userId,
    required String identity,
    required String oldPassword,
    required String password,
  }) => _tokenFormAction(
    server: server,
    token: token,
    path: '/api2/user/updatePwd',
    fields: {'oldPwd': oldPassword, 'pwd': password},
  );

  Future<void> uploadAvatar({
    required Uri server,
    required String token,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      throw const ApiException('invalidAvatarSize');
    }
    return _tokenFormAction(
      server: server,
      token: token,
      path: '/api2/avatar',
      fields: {},
      avatar: bytes,
    );
  }

  /// Explicit online mutation; callers must not automatically retry on timeout.
  Future<String> uploadNoteImage({
    required Uri server,
    required String token,
    required String userId,
    required String noteId,
    required NoteImageUpload image,
    Future<void> Function()? beforeSend,
    String? uploadId,
  }) async {
    if (!RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(noteId)) {
      throw const ApiException('invalidRequest');
    }
    final note = await _requestJson(
      server: server,
      path: '/api2/note/getNote',
      method: 'GET',
      token: token,
      query: {'noteId': noteId},
    );
    if (note['NoteId'] != noteId ||
        note['UserId'] != userId ||
        note['IsDeleted'] == true ||
        note['IsTrash'] == true) {
      throw const ApiException('noPermission');
    }
    final result = await _tokenFormAction(
      server: server,
      token: token,
      path: '/api2/file/pasteImage',
      fields: {'noteId': noteId, 'uploadId': ?uploadId},
      avatar: image.bytes,
      filename: 'image.png',
      beforeSend: beforeSend,
    );
    final id = result['Id'];
    if (id is! String || !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(id)) {
      throw const ApiException('imageUploadUnconfirmed');
    }
    // Never embed a token, cookie or user-supplied URL in note content.
    return '/api2/file/getImage?fileId=$id';
  }

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
    final data = await _requestJson(
      server: server,
      path: '/api2/file/imageUpload',
      method: 'GET',
      token: token,
      query: {'uploadId': uploadId},
    );
    final item = _map(data['Item']);
    final id = _string(item, 'FileId');
    final noteId = _string(item, 'NoteId');
    final digest = _string(item, 'Digest');
    final state = _string(item, 'State');
    if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{24}$').hasMatch(noteId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        !{'pending', 'retained', 'deleting', 'deleted'}.contains(state) ||
        item['CanCleanup'] != (state == 'pending' || state == 'deleting')) {
      throw const ApiException('invalidResponse');
    }
    return (
      fileId: id,
      noteId: noteId,
      digest: digest,
      state: state,
      canCleanup: item['CanCleanup'] == true,
    );
  }

  Future<void> cleanupImageUpload({
    required Uri server,
    required String token,
    required String fileId,
  }) async {
    await _requestFormJson(
      server: server,
      path: '/api2/file/cleanupImageUpload',
      token: token,
      fields: {'fileId': fileId},
    );
  }

  /// Explicit online mutation; callers must not automatically retry on timeout.
  Future<String> uploadAttachment({
    required Uri server,
    required String token,
    required String userId,
    required String noteId,
    required AttachmentUpload file,
    Future<void> Function()? beforeSend,
  }) async {
    if (!RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(noteId)) {
      throw const ApiException('invalidRequest');
    }
    // Token and operation-local cookie session must both belong to this owner.
    final note = await _requestJson(
      server: server,
      path: '/api2/note/getNote',
      method: 'GET',
      token: token,
      query: {'noteId': noteId},
    );
    if (note['NoteId'] != noteId ||
        note['UserId'] != userId ||
        note['IsDeleted'] == true ||
        note['IsTrash'] == true) {
      throw const ApiException('noPermission');
    }
    final result = await _tokenFormAction(
      server: server,
      token: token,
      path: '/api2/attachments/upload',
      fields: {'noteId': noteId},
      avatar: file.bytes,
      filename: file.name,
      beforeSend: beforeSend,
    );
    final id = result['Id'];
    if (id is! String || !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(id)) {
      throw const ApiException('attachmentUploadUnconfirmed');
    }
    return id;
  }

  Future<Map<String, Object?>> _tokenFormAction({
    required Uri server,
    required String token,
    required String path,
    required Map<String, String> fields,
    Uint8List? avatar,
    String filename = 'avatar.png',
    Future<void> Function()? beforeSend,
  }) async {
    final http.BaseRequest request;
    if (avatar != null) {
      request = _multipart('POST', server.resolve(path))
        ..fields.addAll(fields)
        ..files.add(
          http.MultipartFile.fromBytes('file', avatar, filename: filename),
        );
    } else {
      request = _newRequest('POST', server.resolve(path))..bodyFields = fields;
    }
    request.followRedirects = false;
    request.headers['Authorization'] = 'Bearer $token';
    await beforeSend?.call();
    try {
      final response = await _readResponse(await _send(request))
          .timeout(const Duration(seconds: 60));
      final result = _decodeMapResponse(response);
      if (result['Ok'] != true) throw const ApiException('invalidResponse');
      return result;
    } on ApiException {
      rethrow;
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('networkUnavailable');
    }
  }

  Future<List<NoteFile>> noteFiles({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
  }) async {
    final data = await _requestJson(
      server: server,
      path: '/api2/note/getNote',
      method: 'GET',
      token: token,
      query: {'noteId': noteId},
    );
    if (data['NoteId'] != noteId ||
        data['UserId'] != userId ||
        !data.containsKey('Files') ||
        (data['Files'] != null && data['Files'] is! List)) {
      throw const ApiException('invalidResponse');
    }
    if (data['IsDeleted'] == true) throw const ApiException('notExists');
    final result = <NoteFile>[];
    final ids = <String>{};
    try {
      for (final item in data['Files'] as List? ?? []) {
        final file = NoteFile.fromJson(_map(item));
        if (!ids.add(file.id)) throw const FormatException('duplicateFile');
        result.add(file);
      }
    } on FormatException {
      throw const ApiException('invalidResponse');
    }
    return result;
  }

  Future<Uint8List> noteImage({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
    required NoteFile file,
  }) async {
    // Recheck membership rather than trusting an old list or a body-supplied URL.
    final files = await noteFiles(
      server: server,
      token: token,
      noteId: noteId,
      userId: userId,
    );
    if (file.isAttachment ||
        !files.any((item) => item.id == file.id && !item.isAttachment)) {
      throw const ApiException('imageNotInNote');
    }
    return _downloadImage(server, token, file.id);
  }

  Future<Uint8List> historyImage({
    required Uri server,
    required String token,
    required String noteId,
    required String historyId,
    required String fileId,
    required String expectedContent,
    required bool isMarkdown,
  }) async {
    // This endpoint verifies ownership of both note and history server-side.
    final content = await getHistoryContent(
      server: server,
      token: token,
      noteId: noteId,
      historyId: historyId,
    );
    if (content != expectedContent ||
        !bodyImageIds(
          content,
          isMarkdown: isMarkdown,
          server: server,
        ).contains(fileId)) {
      throw const ApiException('imageNotInHistory');
    }
    return _downloadImage(server, token, fileId);
  }

  Future<Uint8List> _downloadImage(
    Uri server,
    String token,
    String fileId,
  ) async {
    final request =
        _newRequest(
            'GET',
            _uri(
              server,
              '/api2/file/getImage',
              token: token,
              query: {'fileId': fileId},
            ),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token';
    try {
      final response = await _send(request)
          .timeout(const Duration(seconds: 15));
      const maxBytes = 8 * 1024 * 1024;
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes ||
          !{'image/png', 'image/jpeg', 'image/gif', 'image/webp'}.contains(
            response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase(),
          )) {
        await response.stream.listen((_) {}).cancel();
        throw const ApiException('invalidImageResponse');
      }
      final bytes = BytesBuilder(copy: false);
      final chunks = StreamIterator(response.stream);
      final timer = Stopwatch()..start();
      try {
        while (await _wait(
          chunks.moveNext().timeout(
            const Duration(seconds: 15) - timer.elapsed,
          ),
        )) {
          if (bytes.length + chunks.current.length > maxBytes) {
            throw const ApiException('imageTooLarge');
          }
          bytes.add(chunks.current);
        }
      } finally {
        await chunks.cancel();
      }
      if (bytes.isEmpty) throw const ApiException('invalidImageResponse');
      return bytes.takeBytes();
    } on ApiException {
      rethrow;
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('imageDownloadFailed');
    }
  }

  Future<Uint8List> noteAttachment({
    required Uri server,
    required String token,
    required String noteId,
    required String userId,
    required NoteFile file,
  }) async {
    final files = await noteFiles(
      server: server,
      token: token,
      noteId: noteId,
      userId: userId,
    );
    if (!file.isAttachment ||
        !files.any((item) => item.id == file.id && item.isAttachment)) {
      throw const ApiException('attachmentNotInNote');
    }
    final request =
        _newRequest(
            'GET',
            _uri(
              server,
              '/api2/file/getAttach',
              token: token,
              query: {'fileId': file.id},
            ),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token';
    try {
      final response = await _send(request)
          .timeout(const Duration(seconds: 30));
      const maxBytes = 32 * 1024 * 1024;
      // This endpoint also returns HTTP 200 for errors. Only an actual download
      // has Content-Disposition: attachment; never save an error/login response.
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes ||
          response.headers['content-disposition']
                  ?.split(';')
                  .first
                  .trim()
                  .toLowerCase() !=
              'attachment') {
        await response.stream.listen((_) {}).cancel();
        throw const ApiException('invalidAttachmentResponse');
      }
      final bytes = BytesBuilder(copy: false);
      final chunks = StreamIterator(response.stream);
      final timer = Stopwatch()..start();
      try {
        while (await _wait(
          chunks.moveNext().timeout(
            const Duration(seconds: 60) - timer.elapsed,
          ),
        )) {
          if (bytes.length + chunks.current.length > maxBytes) {
            throw const ApiException('attachmentTooLarge');
          }
          bytes.add(chunks.current);
        }
      } finally {
        await chunks.cancel();
      }
      // Empty files are valid attachments, unlike images.
      return bytes.takeBytes();
    } on ApiException {
      rethrow;
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('attachmentDownloadFailed');
    }
  }

  Future<Uint8List?> downloadAvatar({
    required Uri server,
    required String logo,
  }) async {
    if (logo.trim().isEmpty) return null;
    final uri = server.resolve(logo);
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.origin != server.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const ApiException('invalidAvatarUrl');
    }
    // Public static resource: no token, cookies or automatic redirects.
    final request = _newRequest('GET', uri)..followRedirects = false;
    try {
      final response = await _send(request)
          .timeout(const Duration(seconds: 15));
      const maxBytes = 2 * 1024 * 1024;
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes ||
          !['image/png', 'image/jpeg', 'image/gif', 'image/webp'].contains(
            response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase(),
          )) {
        await response.stream.listen((_) {}).cancel();
        throw const ApiException('invalidAvatarResponse');
      }
      final bytes = BytesBuilder(copy: false);
      final chunks = StreamIterator(response.stream);
      final timer = Stopwatch()..start();
      try {
        while (await _wait(
          chunks.moveNext().timeout(
            const Duration(seconds: 15) - timer.elapsed,
          ),
        )) {
          final chunk = chunks.current;
          if (bytes.length + chunk.length > maxBytes) {
            throw const ApiException('avatarTooLarge');
          }
          bytes.add(chunk);
        }
      } finally {
        await chunks.cancel();
      }
      if (bytes.isEmpty) throw const ApiException('invalidAvatarResponse');
      return bytes.takeBytes();
    } on ApiException {
      rethrow;
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('avatarDownloadFailed');
    }
  }

  Future<LoginResult> login({
    required Uri server,
    required String identity,
    required String password,
  }) async {
    final data = await _requestJson(
      server: server,
      path: '/api2/auth/login',
      method: 'POST',
      body: <String, Object?>{'email': identity, 'pwd': password},
    );
    final token = _string(data, 'Token');
    final user = _map(data['User']);
    final version = _map(data['Server']);
    if (_string(version, 'Name').toLowerCase() != 'gemsnote') {
      throw const ApiException('serverMigrationRequired');
    }
    return LoginResult(
      token: token,
      account: Account.fromJson(
        user,
        server: server,
        apiVersion: _string(version, 'Version'),
      ),
      serverVersion: _string(version, 'Version'),
      minimumClientVersion: version['MinVersion']?.toString() ?? '',
    );
  }

  Future<int> getSyncUsn({required Uri server, required String token}) async {
    final data = await _requestJson(
      server: server,
      path: '/api2/user/getSyncState',
      method: 'GET',
      token: token,
    );
    final value = data['LastSyncUsn'];
    if (value is! int || value < 0) {
      throw const ApiException('invalidSyncState');
    }
    return value;
  }

  Future<List<Notebook>> getNotebooks({
    required Uri server,
    required String token,
    required int afterUsn,
    int maxEntry = 100,
  }) async {
    final data = await _requestList(
      server: server,
      path: '/api2/notebook/getSyncNotebooks',
      token: token,
      query: {'afterUsn': '$afterUsn', 'maxEntry': '$maxEntry'},
    );
    return data.map(Notebook.fromJson).toList(growable: false);
  }

  Future<List<Note>> getNotesWithContent({
    required Uri server,
    required String token,
    required int afterUsn,
    int maxEntry = syncNotePageSize,
  }) async {
    final data = await _requestList(
      server: server,
      path: '/api2/note/getSyncNotesWithContent',
      token: token,
      query: {'afterUsn': '$afterUsn', 'maxEntry': '$maxEntry'},
      timeout: noteContentTimeout,
    );
    return data.map(Note.fromJson).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> getTags({
    required Uri server,
    required String token,
    required int afterUsn,
    int maxEntry = 100,
  }) {
    return _requestList(
      server: server,
      path: '/api2/tag/getSyncTags',
      token: token,
      query: {'afterUsn': '$afterUsn', 'maxEntry': '$maxEntry'},
    );
  }

  Future<int> createTag({
    required Uri server,
    required String token,
    required String userId,
    required String name,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: '/api2/tag/addTag',
      token: token,
      fields: {'tag': name},
    );
    final usn = data['Usn'];
    if (data['Tag'] != name ||
        data['UserId'] != userId ||
        data['IsDeleted'] != false ||
        usn is! int ||
        usn <= 0) {
      throw const ApiException('invalidResponse');
    }
    return usn;
  }

  Future<int> deleteTag({
    required Uri server,
    required String token,
    required String name,
    required int usn,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: '/api2/tag/deleteTag',
      token: token,
      fields: {'tag': name, 'usn': '$usn'},
    );
    if (data['Ok'] != true ||
        data['Usn'] is! int ||
        (data['Usn'] as int) <= usn) {
      throw const ApiException('invalidResponse');
    }
    return data['Usn'] as int;
  }

  Future<List<SharedNote>> sharedNotes({
    required Uri server,
    required String token,
    void Function(SharingNavigation)? onNavigation,
  }) async {
    final capabilities = await _requestJson(
      server: server,
      path: '/api2/shared/capabilities',
      method: 'GET',
      token: token,
    );
    if (capabilities['Ok'] != true ||
        capabilities['ProtocolVersion'] != 1 ||
        capabilities['Snapshot'] != true) {
      throw const ApiException('sharedProtocolUnsupported');
    }
    final snapshot = await _requestJson(
      server: server,
      path: '/api2/shared/snapshots',
      method: 'POST',
      token: token,
      body: {},
    );
    final id = snapshot['SnapshotId'];
    final total = snapshot['Total'];
    if (snapshot['Ok'] != true ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        total is! int ||
        total < 0 ||
        total > 10000) {
      throw const ApiException('invalidSharedSnapshot');
    }
    final result = <SharedNote>[];
    final files = <(String, String), SharedFile>{};
    final ids = <String>{};
    var received = 0;
    var cursor = '';
    while (true) {
      final page = await _requestJson(
        server: server,
        path: '/api2/shared/snapshots/$id/items',
        method: 'GET',
        token: token,
        query: {'pageToken': cursor},
      );
      if (page['Ok'] != true ||
          page['Items'] is! List ||
          page['Total'] != total ||
          page['Complete'] is! bool ||
          page['NextPageToken'] is! String) {
        throw const ApiException('invalidSharedSnapshot');
      }
      final items = page['Items'] as List;
      received += items.length;
      if (received > total) throw const ApiException('invalidSharedSnapshot');
      for (final item in items) {
        final data = _map(item);
        if (data['Kind'] == 'note') {
          final note = SharedNote.fromJson(_map(data['Note']));
          if (!ids.add(note.note.noteId)) {
            throw const ApiException('duplicateSharedNote');
          }
          result.add(note);
        } else if (data['Kind'] == 'file') {
          try {
            final file = SharedFile.fromJson(_map(data['File']));
            final key = (file.noteId, file.fileId);
            if (files.containsKey(key)) {
              throw const FormatException('duplicateSharedFile');
            }
            files[key] = file;
          } on FormatException {
            throw const ApiException('invalidSharedSnapshot');
          }
        } else if (data['Kind'] != 'notebook') {
          throw const ApiException('invalidSharedSnapshot');
        }
      }
      if (page['Complete'] == true) {
        if (received != total || page['NextPageToken'] != '') {
          throw const ApiException('invalidSharedSnapshot');
        }
        break;
      }
      if (items.isEmpty ||
          received >= total ||
          page['NextPageToken'] != '$received') {
        throw const ApiException('invalidSharedSnapshot');
      }
      cursor = page['NextPageToken'] as String;
    }
    if (files.values.any((file) => !ids.contains(file.noteId))) {
      throw const ApiException('invalidSharedSnapshot');
    }
    for (var i = 0; i < result.length; i++) {
      final note = result[i];
      result[i] = SharedNote(
        note: note.note,
        version: note.version,
        files: files.values
            .where((file) => file.noteId == note.note.noteId)
            .toList(growable: false),
      );
    }
    result.sort((a, b) {
      final order = a.note.title.toLowerCase().compareTo(
        b.note.title.toLowerCase(),
      );
      return order == 0 ? a.note.noteId.compareTo(b.note.noteId) : order;
    });
    if (snapshot['Sharing'] is Map) {
      onNavigation?.call(SharingNavigation.fromJson(_map(snapshot['Sharing'])));
    }
    return result;
  }

  Future<Note> sharedContent({
    required Uri server,
    required String token,
    required SharedNote shared,
  }) async {
    final data = await _requestJson(
      server: server,
      path: '/api2/shared/notes/${shared.note.noteId}/content',
      method: 'GET',
      token: token,
    );
    if (data['Ok'] != true ||
        data['NoteId'] != shared.note.noteId ||
        data['Content'] is! String) {
      throw const ApiException('invalidResponse');
    }
    if (data['Version'] != shared.version || data['Digest'] != shared.version) {
      throw const ApiException('sharedContentChanged');
    }
    return shared.note.copyWith(content: data['Content'] as String);
  }

  Future<void> copySharedNote({
    required Uri server,
    required String token,
    required SharedNote shared,
    required String notebookId,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: '/api2/note/copySharedNote',
      token: token,
      fields: {
        'noteIds[0]': shared.note.noteId,
        'notebookId': notebookId,
        'fromUserId': shared.note.userId,
      },
    );
    if (data['Ok'] != true || data['Item'] is! List) {
      throw const ApiException('copySharedFailed');
    }
    final items = data['Item'] as List;
    if (items.length != 1 ||
        _map(items.single)['UserId'] == shared.note.userId ||
        _map(items.single)['NotebookId'] != notebookId) {
      throw const ApiException('copySharedFailed');
    }
  }

  Future<Uint8List> sharedFile({
    required Uri server,
    required String token,
    required SharedNote shared,
    required SharedFile file,
  }) async {
    if (file.noteId != shared.note.noteId ||
        !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(file.noteId) ||
        !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(file.fileId) ||
        !shared.files.any((entry) => entry.sameVersion(file))) {
      throw const ApiException('fileNotInSharedSnapshot');
    }
    if (file.size > file.maxBytes) {
      throw const ApiException('sharedFileTooLarge');
    }
    await sharedContent(server: server, token: token, shared: shared);
    final request =
        _newRequest(
            'GET',
            _uri(
              server,
              '/api2/shared/notes/${file.noteId}/files/${file.fileId}',
              token: token,
            ),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token';
    try {
      final response = await _send(request)
          .timeout(const Duration(seconds: 15));
      final digest = response.headers['x-gemsnote-sha256'];
      final isErrorEnvelope =
          digest == null &&
          response.headers['content-type']
                  ?.split(';')
                  .first
                  .trim()
                  .toLowerCase() ==
              'application/json';
      final bound = isErrorEnvelope ? 16384 : file.maxBytes;
      if ((response.contentLength ?? 0) > bound ||
          (!isErrorEnvelope &&
              (response.statusCode != 200 || digest != file.version))) {
        await response.stream.listen((_) {}).cancel();
        throw const ApiException('sharedFileChanged');
      }
      final bytes = BytesBuilder(copy: false);
      final chunks = StreamIterator(response.stream);
      final timer = Stopwatch()..start();
      try {
        while (await _wait(
          chunks.moveNext().timeout(
            const Duration(seconds: 30) - timer.elapsed,
          ),
        )) {
          if (bytes.length + chunks.current.length > bound) {
            throw const ApiException('sharedFileTooLarge');
          }
          bytes.add(chunks.current);
        }
      } finally {
        await chunks.cancel();
      }
      final value = bytes.takeBytes();
      if (isErrorEnvelope) {
        final error = _map(jsonDecode(utf8.decode(value)));
        throw ApiException(
          error['Msg'] == 'noPermission'
              ? 'noPermission'
              : error['Msg'] == 'fileNotFound'
              ? 'fileNotFound'
              : 'invalidSharedFileResponse',
        );
      }
      if (value.length != file.size ||
          crypto.sha256.convert(value).toString() != file.version ||
          (!file.isAttachment &&
              !{'image/png', 'image/jpeg', 'image/gif', 'image/webp'}.contains(
                response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase(),
              ))) {
        throw const ApiException('sharedFileChanged');
      }
      // Detect a permission/content change that happened during this transfer.
      await sharedContent(server: server, token: token, shared: shared);
      return value;
    } on ApiException {
      rethrow;
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('sharedFileDownloadFailed');
    }
  }

  Future<void> logout({required Uri server, required String token}) async {
    await _requestJson(
      server: server,
      path: '/api2/auth/logout',
      method: 'POST',
      token: token,
      body: const <String, Object?>{},
    );
  }

  Future<Account> userInfo({required Uri server, required String token}) async {
    final data = await _requestJson(
      server: server,
      path: '/api2/user/info',
      method: 'GET',
      token: token,
    );
    return Account.fromJson(data, server: server);
  }

  Future<void> requestPasswordReset({
    required Uri server,
    required String email,
  }) async {
    final response = await _requestJson(
      server: server,
      path: '/api2/auth/password/request',
      method: 'POST',
      body: {'email': email},
    );
    if (response['Ok'] != true) throw const ApiException('invalidResponse');
  }

  Future<List<NoteHistory>> getHistories({
    required Uri server,
    required String token,
    required String noteId,
  }) async {
    final response = await _requestJson(
      server: server,
      path: '/api2/note/getHistories',
      method: 'GET',
      token: token,
      query: {'noteId': noteId},
    );
    if (response['Ok'] != true || response['Item'] is! List) {
      throw const ApiException('invalidResponse');
    }
    return (response['Item'] as List)
        .map((item) => NoteHistory.fromJson(_map(item)))
        .toList(growable: false);
  }

  Future<void> deleteNotebook({
    required Uri server,
    required String token,
    required Notebook notebook,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: '/api2/client/notebook/delete',
      token: token,
      fields: {'notebookId': notebook.notebookId, 'usn': '${notebook.usn}'},
    );
    if (data['Ok'] != true) {
      throw ApiException(data['Msg']?.toString() ?? 'deleteNotebookFailed');
    }
  }

  Future<void> restoreHistorySnapshot({
    required Uri server,
    required String token,
    required String noteId,
    required String historyId,
    required int usn,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: '/api2/note/restoreHistory',
      token: token,
      fields: {'noteId': noteId, 'historyId': historyId, 'usn': '$usn'},
    );
    if (data['Ok'] != true) throw const ApiException('invalidResponse');
  }

  Future<String> getHistoryContent({
    required Uri server,
    required String token,
    required String noteId,
    required String historyId,
  }) async {
    if (historyId.isEmpty) throw const ApiException('invalidHistoryId');
    final response = await _requestJson(
      server: server,
      path: '/api2/note/getHistoryContent',
      method: 'GET',
      token: token,
      query: {'noteId': noteId, 'historyId': historyId},
    );
    final item = _map(response['Item']);
    if (response['Ok'] != true ||
        item['HistoryId'] != historyId ||
        item['Content'] is! String) {
      throw const ApiException('invalidResponse');
    }
    return item['Content'] as String;
  }

  Future<Note> addNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: '/api2/client/note/add',
      token: token,
      fields: _noteFields(note, isNew: true),
    );
    return Note.fromJson(data);
  }

  Future<Notebook> saveNotebook({
    required Uri server,
    required String token,
    required String title,
    String? parentNotebookId,
    Notebook? existing,
    String? clientNotebookId,
  }) async {
    final data = await _requestFormJson(
      server: server,
      path: existing == null
          ? '/api2/client/notebook/add'
          : '/api2/client/notebook/update',
      token: token,
      fields: {
        'title': title,
        'parentNotebookId':
            parentNotebookId ?? existing?.parentNotebookId ?? '',
        'seq': '${existing?.sequence ?? 0}',
        if (existing != null) 'notebookId': existing.notebookId,
        if (existing != null) 'usn': '${existing.usn}',
        if (existing == null && clientNotebookId != null)
          'clientNotebookId': clientNotebookId,
      },
    );
    final notebook = Notebook.fromJson(data);
    if (!RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(notebook.notebookId) ||
        notebook.usn <= 0 ||
        (existing != null && notebook.notebookId != existing.notebookId)) {
      throw const ApiException('invalidResponse');
    }
    if (clientNotebookId != null && notebook.notebookId != clientNotebookId) {
      throw const ApiException('creationKeyNotAcknowledged');
    }
    return notebook;
  }

  Future<void> deleteTrash({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    // A new note may have reached the server before an add response was lost.
    // Never delete an unacknowledged server version using a guessed USN.
    if (note.usn == 0) {
      try {
        final current = await _requestJson(
          server: server,
          path: '/api2/note/getNote',
          method: 'GET',
          token: token,
          query: {'noteId': note.noteId},
        );
        if (current['NoteId'] == note.noteId && current['IsDeleted'] == true) {
          return;
        }
      } on ApiException catch (error) {
        if (error.code == 'notExists' && error.statusCode == null) return;
        rethrow;
      }
      throw const ApiException('unconfirmedNoteDeletion');
    }
    try {
      final response = await _requestFormJson(
        server: server,
        path: '/api2/client/note/deleteTrash',
        token: token,
        fields: {'noteId': note.noteId, 'usn': '${note.usn}'},
      );
      final usn = response['Usn'];
      if (response['Ok'] != true || usn is! int || usn <= note.usn) {
        throw const ApiException('invalidResponse');
      }
    } on ApiException catch (error) {
      // The previous attempt may have succeeded before its response was lost.
      if (error.code == 'notExists' && error.statusCode == null) return;
      rethrow;
    }
  }

  /// Bracket the body read with metadata reads: these API2 endpoints are
  /// separate requests and must not combine different remote revisions.
  Future<({Note note, bool filesConfirmedEmpty})> getConflictSnapshot({
    required Uri server,
    required String token,
    required String noteId,
  }) async {
    Future<Map<String, Object?>> metadata() async {
      final data = await _requestJson(
        server: server,
        path: '/api2/note/getNote',
        method: 'GET',
        token: token,
        query: {'noteId': noteId},
      );
      if (data['NoteId'] != noteId ||
          data['Usn'] is! int ||
          (data['Usn'] as int) <= 0 ||
          [
            'UserId',
            'NotebookId',
            'Title',
            'CreatedTime',
            'UpdatedTime',
          ].any((key) => data[key] is! String) ||
          [
            'IsMarkdown',
            'IsStar',
            'IsTrash',
            'IsDeleted',
          ].any((key) => data[key] is! bool) ||
          !data.containsKey('Tags') ||
          (data['Tags'] != null &&
              (data['Tags'] is! List ||
                  (data['Tags'] as List).any((tag) => tag is! String)))) {
        throw const ApiException('invalidResponse');
      }
      return data;
    }

    final before = await metadata();
    if (before['IsDeleted'] == true) {
      // API2 removes the content on permanent deletion. Two matching metadata
      // reads still provide a stable tombstone for preserving a local draft.
      final after = await metadata();
      if (jsonEncode(before) != jsonEncode(after)) {
        throw const ApiException('conflict');
      }
      return (
        note: Note.fromJson({...after, 'Content': ''}),
        filesConfirmedEmpty: false,
      );
    }
    final body = await _requestJson(
      server: server,
      path: '/api2/note/getNoteContent',
      method: 'GET',
      token: token,
      query: {'noteId': noteId},
    );
    if (body['NoteId'] != noteId ||
        body['Content'] is! String ||
        body['UserId'] != before['UserId']) {
      throw const ApiException('invalidResponse');
    }
    final after = await metadata();
    if (before['Usn'] != after['Usn']) {
      throw const ApiException('conflict');
    }
    return (
      note: Note.fromJson({...after, 'Content': body['Content']}),
      filesConfirmedEmpty:
          before['Files'] is List &&
          (before['Files'] as List).isEmpty &&
          after['Files'] is List &&
          (after['Files'] as List).isEmpty,
    );
  }

  Future<Note> updateNote({
    required Uri server,
    required String token,
    required Note note,
  }) async {
    // The server treats Files as the complete retained attachment list.
    // Until mobile attachment editing is implemented, preserve the current
    // remote references, guarded by the same USN used for the update.
    final current = await _requestJson(
      server: server,
      path: '/api2/note/getNote',
      method: 'GET',
      token: token,
      query: {'noteId': note.noteId},
    );
    if (current['NoteId'] != note.noteId || current['Usn'] is! num) {
      throw const ApiException('invalidResponse');
    }
    if (current['Usn'] != note.usn) throw const ApiException('conflict');
    if (!current.containsKey('Files') ||
        (current['Files'] != null && current['Files'] is! List)) {
      throw const ApiException('invalidResponse');
    }
    final fields = _noteFields(note, isNew: false);
    final files = current['Files'] as List? ?? const [];
    for (var index = 0; index < files.length; index++) {
      final file = _map(files[index]);
      final id = _string(file, 'FileId');
      if (!RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(id) ||
          file['IsAttach'] is! bool) {
        throw const ApiException('invalidResponse');
      }
      fields.addAll({
        'Files[$index][FileId]': id,
        'Files[$index][LocalFileId]': id,
        'Files[$index][IsAttach]': '${file['IsAttach']}',
        'Files[$index][HasBody]': 'false',
        'Files[$index][Type]': file['Type']?.toString() ?? '',
        'Files[$index][Title]': file['Title']?.toString() ?? '',
      });
    }
    final data = await _requestFormJson(
      server: server,
      path: '/api2/client/note/update',
      token: token,
      fields: fields,
    );
    return Note.fromJson(data);
  }

  Future<Map<String, Object?>> _requestFormJson({
    required Uri server,
    required String path,
    required String token,
    required Map<String, String> fields,
    String? language,
  }) async => _map(
    await _requestFormValue(
      server: server,
      path: path,
      token: token,
      fields: fields,
      language: language,
    ),
  );

  Future<Object?> _requestFormValue({
    required Uri server,
    required String path,
    required String token,
    required Map<String, String> fields,
    String? language,
  }) async {
    final uri = _uri(server, path, token: token);
    late http.Response response;
    try {
      final request = _newRequest('POST', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $token'
        ..bodyFields = fields;
      if (language != null) request.headers['Accept-Language'] = language;
      response = await (() async => _readResponse(
        await _send(request),
      ))().timeout(const Duration(minutes: 2));
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('networkUnavailable');
    }
    return _decodeResponse(response);
  }

  Future<List<Map<String, Object?>>> _requestList({
    required Uri server,
    required String path,
    required String token,
    Map<String, String> query = const {},
    Duration? timeout,
  }) async {
    final value = await _request(
      server: server,
      path: path,
      method: 'GET',
      token: token,
      query: query,
      timeout: timeout,
    );
    if (value is! List) throw const ApiException('invalidResponse');
    return value.map((item) => _map(item)).toList(growable: false);
  }

  Future<Map<String, Object?>> _requestJson({
    required Uri server,
    required String path,
    required String method,
    String? token,
    Map<String, String> query = const {},
    Object? body,
  }) async {
    final value = await _request(
      server: server,
      path: path,
      method: method,
      token: token,
      query: query,
      body: body,
    );
    return _map(value);
  }

  Future<Object?> _request({
    required Uri server,
    required String path,
    required String method,
    String? token,
    Map<String, String> query = const {},
    Object? body,
    Duration? timeout,
  }) async {
    final uri = _uri(server, path, token: token, query: query);
    late http.Response response;
    final abort = Completer<void>();
    try {
      final request = _newRequest(method, uri, abort: abort.future)
        ..followRedirects = false;
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      if (method == 'POST') {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      response = await (() async => _readResponse(
        await _send(request),
      ))().timeout(timeout ?? requestTimeout);
    } on TimeoutException {
      Cancellation.current?.check();
      throw ApiException(
        path == '/api2/note/getSyncNotesWithContent'
            ? 'noteDownloadTimedOut'
            : 'requestTimedOut',
      );
    } on Exception {
      Cancellation.current?.check();
      throw const ApiException('networkUnavailable');
    } finally {
      // Future.timeout alone leaves the underlying HTTP request running. Abort
      // this request without closing the shared client or another operation.
      abort.complete();
    }
    return _decodeResponse(response);
  }

  Uri _uri(
    Uri server,
    String path, {
    String? token,
    Map<String, String> query = const {},
  }) => server
      .resolve(path)
      .replace(
        queryParameters: <String, String>{
          ...query,
          'v': 'mobile_$clientVersion',
        },
      );

  static Object? _decodeResponse(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException('invalidJSON', statusCode: response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final data = decoded is Map ? _map(decoded) : const <String, Object?>{};
      throw ApiException(
        data['Msg']?.toString() ?? 'http${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    if (decoded is Map) {
      final data = _map(decoded);
      if (data['Ok'] == false) {
        throw ApiException(data['Msg']?.toString() ?? 'requestFailed');
      }
    }
    return decoded;
  }

  static Map<String, Object?> _decodeMapResponse(http.Response response) =>
      _map(_decodeResponse(response));

  static Map<String, String> _noteFields(Note note, {required bool isNew}) {
    final fields = <String, String>{
      if (isNew) 'ClientNoteId': note.noteId else 'NoteId': note.noteId,
      'NotebookId': note.notebookId,
      'Title': note.title,
      'Content': note.content,
      'IsMarkdown': '${note.isMarkdown}',
      'IsTrash': '${note.isTrash}',
      'IsBlog': 'false',
      'IsStar': '${note.isStarred}',
      'CreatedTime': note.createdTime,
      'UpdatedTime': note.updatedTime,
    };
    if (!isNew) fields['Usn'] = '${note.usn}';
    if (!isNew && note.tags.isEmpty) fields['ClearTags'] = 'true';
    for (var index = 0; index < note.tags.length; index++) {
      fields['Tags[$index]'] = note.tags[index];
    }
    return fields;
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map) throw const ApiException('invalidResponse');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static String _string(Map<String, Object?> value, String key) {
    final result = value[key]?.toString() ?? '';
    if (result.isEmpty) throw const ApiException('invalidResponse');
    return result;
  }
}
