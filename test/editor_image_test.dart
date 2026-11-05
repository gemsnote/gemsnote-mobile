import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/services/note_image_picker.dart';
import 'package:gemsnote/ui/note_editor_page.dart';
import 'package:gemsnote/ui/note_image_upload_dialog.dart';

const reference = '/api2/file/getImage?fileId=507f1f77bcf86cd799439012';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NoteImageUpload image;
  setUpAll(() async {
    image = await NoteImageUpload.normalize(
      File('assets/images/gemsnote_s.png').readAsBytesSync(),
    );
  });
  Future<void> open(
    WidgetTester tester, {
    bool markdown = true,
    Future<NoteImageUpload?> Function()? pick,
    Future<void> Function(NoteImageUpload)? stage,
    required Future<void> Function(String, String) save,
    required Future<String> Function(NoteImageUpload) upload,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorPage(
          note: Note.fromJson({
            'NoteId': 'n',
            'Title': 'Title',
            'Content': 'Body',
            'IsMarkdown': markdown,
          }),
          pickImage: pick ?? () async => image,
          saveText: save,
          uploadImage: upload,
          stageImage: stage,
        ),
      ),
    );
  }

  Future<void> choose(WidgetTester tester, {bool markdown = true}) async {
    await tester.tap(find.byTooltip(markdown ? '插入图片' : '在文末插入图片'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'offline image staging saves current text first without network or credentials',
    (tester) async {
      final events = <String>[];
      await open(
        tester,
        save: (_, body) async {
          events.add('save:$body');
        },
        stage: (picked) async {
          expect(picked.bytes, image.bytes);
          events.add('stage');
        },
        upload: (_) async => throw StateError('must not upload'),
      );
      await tester.enterText(find.byType(TextField).last, 'offline draft');
      await tester.tap(find.byTooltip('离线暂存图片'));
      await tester.pumpAndSettle();
      expect(events, ['save:offline draft', 'stage']);
      expect(find.byType(NoteImageUploadDialog), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'offline draft',
      );
      expect(find.textContaining('图片已暂存到本机'), findsOneWidget);
    },
  );

  testWidgets(
    'failed draft save prevents staging an image against stale text',
    (tester) async {
      var stages = 0;
      await open(
        tester,
        save: (_, _) async => throw StateError('disk full'),
        stage: (_) async {
          stages++;
        },
        upload: (_) async => throw StateError('must not upload'),
      );
      await tester.enterText(find.byType(TextField).last, 'offline draft');
      await tester.tap(find.byTooltip('离线暂存图片'));
      await tester.pumpAndSettle();
      expect(stages, 0);
      expect(find.textContaining('保存到本地失败'), findsOneWidget);
    },
  );

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.text('上传并插入'));
  }

  for (final markdown in [true, false]) {
    testWidgets(
      'inserts and saves ${markdown ? 'Markdown selection' : 'HTML at end'} without losing text',
      (tester) async {
        final saved = <String>[];
        var uploads = 0;
        await open(
          tester,
          markdown: markdown,
          save: (_, body) async => saved.add(body),
          upload: (_) async {
            uploads++;
            return reference;
          },
        );
        final controller = tester
            .widget<TextField>(find.byType(TextField).last)
            .controller!;
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 2,
        );
        await choose(tester, markdown: markdown);
        await submit(tester);
        await tester.pumpAndSettle();
        expect(uploads, 1);
        final expected = markdown
            ? 'Bo\n![]($reference)\ndy'
            : 'Body\n<img src="$reference" alt="">\n';
        expect(controller.text, expected);
        expect(saved, [expected]);
        expect(find.textContaining('正文待同步'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'picker and confirmation cancellation do not upload or alter body',
    (tester) async {
      var uploads = 0;
      final saved = <String>[];
      Future<String> upload(NoteImageUpload _) async {
        uploads++;
        return reference;
      }

      await open(
        tester,
        pick: () async => null,
        save: (_, body) async => saved.add(body),
        upload: upload,
      );
      await choose(tester);
      expect(find.byType(NoteImageUploadDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await open(
        tester,
        save: (_, body) async => saved.add(body),
        upload: upload,
      );
      await choose(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(uploads, 0);
      expect(saved, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Body',
      );
    },
  );

  testWidgets('draft save failure blocks upload before credentials dialog', (
    tester,
  ) async {
    var uploads = 0;
    await open(
      tester,
      save: (_, _) async => throw StateError('disk full'),
      upload: (_) async {
        uploads++;
        return reference;
      },
    );
    await tester.enterText(find.byType(TextField).last, 'Draft');
    await choose(tester);
    expect(find.byType(NoteImageUploadDialog), findsNothing);
    expect(find.textContaining('保存到本地失败'), findsOneWidget);
    expect(uploads, 0);
  });

  testWidgets(
    'local save retry retains uploaded reference without uploading twice',
    (tester) async {
      var fail = true;
      var uploads = 0;
      final saved = <String>[];
      await open(
        tester,
        save: (_, body) async {
          if (fail) throw StateError('disk full');
          saved.add(body);
        },
        upload: (_) async {
          uploads++;
          return reference;
        },
      );
      await choose(tester);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('保存到本地失败'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        contains(reference),
      );
      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(saved.single, contains(reference));
      expect(uploads, 1);
    },
  );

  testWidgets(
    'in-flight upload blocks duplicate submit and back; failure cannot retry mutation',
    (tester) async {
      final gate = Completer<String>();
      var uploads = 0;
      await open(
        tester,
        save: (_, _) async {},
        upload: (_) {
          uploads++;
          return gate.future;
        },
      );
      await choose(tester);
      await submit(tester);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '上传并插入'))
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(NoteImageUploadDialog), findsOneWidget);
      gate.completeError(TimeoutException('timeout'));
      await tester.pumpAndSettle();
      expect(find.textContaining('结果未确认'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '上传并插入'))
            .onPressed,
        isNull,
      );
      expect(
        find.descendant(
          of: find.byType(NoteImageUploadDialog),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Body',
      );
      expect(uploads, 1);
    },
  );
}
