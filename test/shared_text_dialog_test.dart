import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/notebook.dart';
import 'package:gemsnote/services/shared_text_inbox.dart';
import 'package:gemsnote/ui/shared_text_dialog.dart';

void main() {
  final source = SharedText(
    id: '507f1f77bcf86cd799439012',
    title: 'Shared title',
    text: 'Shared body',
  );
  final note = Note.fromJson({'NoteId': source.id});
  Future<void> open(
    WidgetTester tester, {
    required Future<Note> Function(SharedText, String) save,
    required Future<void> Function() ack,
    bool canImport = true,
    SharedText? resource,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<Note>(
                context: context,
                builder: (_) => SharedTextDialog(
                  source: resource ?? source,
                  notebooks: [
                    Notebook.fromJson({
                      'NotebookId': 'b',
                      'Title': 'Target book',
                    }),
                  ],
                  accountLabel: 'user · https://example.test',
                  canImport: canImport,
                  onImport: save,
                  onAcknowledge: ack,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'requires target selection and permits editing before saving and acknowledging',
    (tester) async {
      final events = <String>[];
      await open(
        tester,
        save: (edited, target) async {
          expect(edited.text, 'Edited body');
          expect(target, 'b');
          events.add('save');
          return note;
        },
        ack: () async => events.add('ack'),
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存笔记'))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.widgetWithText(TextField, '分享正文'),
        'Edited body',
      );
      await tester.ensureVisible(find.text('Target book'));
      await tester.tap(find.text('Target book'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存笔记'));
      await tester.pumpAndSettle();
      expect(events, ['save', 'ack']);
      expect(find.byType(SharedTextDialog), findsNothing);
    },
  );

  testWidgets(
    'resource metadata survives edits and image can be imported as original attachment',
    (tester) async {
      final events = <String>[];
      await open(
        tester,
        resource: SharedText(
          id: source.id,
          title: 'photo',
          text: 'caption',
          resourceKind: 'image',
          resourceName: 'photo.jpg',
          resourceSize: 123,
        ),
        save: (edited, target) async {
          expect(edited.resourceKind, 'attachment');
          expect(edited.resourceName, 'photo.jpg');
          expect(edited.resourceSize, 123);
          events.add('save');
          return note;
        },
        ack: () async {
          events.add('ack');
        },
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Target book'));
      await tester.tap(find.text('Target book'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存笔记'));
      await tester.pumpAndSettle();
      expect(events, ['save', 'ack']);
    },
  );
  testWidgets(
    'save failure retains share; acknowledgement retry does not save twice',
    (tester) async {
      var saves = 0;
      var acks = 0;
      await open(
        tester,
        save: (_, _) async {
          saves++;
          if (saves == 1) throw StateError('disk');
          return note;
        },
        ack: () async {
          acks++;
          if (acks == 1) throw StateError('channel');
        },
      );
      await tester.ensureVisible(find.text('Target book'));
      await tester.tap(find.text('Target book'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存笔记'));
      await tester.pumpAndSettle();
      expect(acks, 0);
      expect(find.textContaining('导入失败'), findsOneWidget);
      await tester.tap(find.text('保存笔记'));
      await tester.pumpAndSettle();
      expect(find.textContaining('笔记已保存'), findsOneWidget);
      await tester.tap(find.text('重试清理'));
      await tester.pumpAndSettle();
      expect(saves, 2);
      expect(acks, 2);
    },
  );
  testWidgets('later keeps pending share; foreign account disables import', (
    tester,
  ) async {
    var writes = 0;
    await open(
      tester,
      canImport: false,
      save: (_, _) async {
        writes++;
        return note;
      },
      ack: () async {
        writes++;
      },
    );
    expect(find.textContaining('此分享已指定其他账号'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存笔记'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('稍后处理'));
    await tester.pumpAndSettle();
    expect(writes, 0);
  });
}
