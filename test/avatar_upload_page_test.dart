import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/avatar_picker.dart';
import 'package:gemsnote/ui/account_page.dart';
import 'package:gemsnote/ui/account_avatar.dart';

import 'account_avatar_widget_test.dart' show AvatarRepository;

class TestPicker extends AvatarPicker {
  TestPicker(this.bytes);
  final Uint8List? bytes;
  @override
  bool get cameraSupported => false;
  @override
  Future<Uint8List?> pick() async => bytes;
}

class UploadRepository extends AvatarRepository {
  int uploads = 0;
  Uint8List? uploaded;
  @override
  Future<void> uploadAvatar(
    StoredSession session, {
    required Uint8List bytes,
  }) async {
    uploads++;
    uploaded = bytes;
  }

  @override
  Future<void> refreshAccountPresentation(StoredSession session) async {
    refreshes++;
    avatar = uploaded;
  }
}

void main() {
  for (final cancel in [true, false]) {
    testWidgets(
      'avatar picker cancellation/upload refreshes current page: $cancel',
      (tester) async {
        final repo = UploadRepository();
        final image = File('assets/images/gemsnote_s.png').readAsBytesSync();
        final session = StoredSession(
          account: Account(
            userId: 'u',
            server: Uri.parse('https://notes.test'),
            username: 'u',
            email: '',
            logo: '',
          ),
          token: 'test',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AccountPage(
              repository: repo,
              session: session,
              avatarPicker: TestPicker(cancel ? null : image),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更换头像'));
        // The account page remains busy while its confirmation dialog is open.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        if (cancel) {
          expect(repo.uploads, 0);
          expect(repo.refreshes, 0);
        } else {
          for (var i = 0; i < 5; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.tap(find.text('使用此头像'));
          for (var i = 0; i < 5; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.tap(find.text('上传'));
          await tester.pumpAndSettle();
          expect(repo.uploads, 1);
          expect(repo.refreshes, 1);
          expect(
            tester.widget<AccountAvatar>(find.byType(AccountAvatar)).bytes,
            repo.uploaded,
          );
          expect(find.text('头像已上传，正在刷新'), findsOneWidget);
        }
      },
    );
  }
}
