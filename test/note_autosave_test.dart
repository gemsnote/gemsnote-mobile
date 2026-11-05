import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_editor_page.dart';

void main() {
  final note = Note.fromJson({
    'NoteId': 'n',
    'Title': 'Title',
    'Content': 'Body',
    'IsMarkdown': true,
  });

  testWidgets('unchanged editor does not save; typing is debounced', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorPage(
          note: note,
          saveText: (title, body) async => saved.add(body),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(saved, isEmpty);
    await tester.enterText(find.byType(TextField).last, 'A');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'B');
    await tester.pump(const Duration(milliseconds: 599));
    expect(saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(saved, ['B']);
    await tester.pump(const Duration(seconds: 1));
    expect(saved, ['B']);
  });

  testWidgets(
    'in-flight saves serialize subsequent edits and background flushes',
    (tester) async {
      final first = Completer<void>();
      final saved = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NoteEditorPage(
            note: note,
            saveText: (title, body) async {
              saved.add(body);
              if (saved.length == 1) await first.future;
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).last, 'A');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(find.byType(TextField).last, 'B');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(saved, ['A']);
      first.complete();
      await tester.pump();
      expect(saved, ['A', 'B']);
      await tester.enterText(find.byType(TextField).last, 'C');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(saved, ['A', 'B', 'C']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  testWidgets(
    'back waits for persistence and unchanged return does not write',
    (tester) async {
      final pending = Completer<void>();
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NoteEditorPage(
                      note: note,
                      saveText: (_, _) {
                        writes++;
                        return pending.future;
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Changed title');
      await tester.pageBack();
      await tester.pump();
      expect(writes, 1);
      expect(find.byType(NoteEditorPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).readOnly,
        isTrue,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorPage), findsNothing);
    },
  );

  testWidgets('failed exit preserves editor and retry saves before leaving', (
    tester,
  ) async {
    var fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoteEditorPage(
                    note: note,
                    saveText: (_, _) async {
                      if (fail) throw StateError('disk full');
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Unsaved');
    await tester.tap(find.byTooltip('保存到本地'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存到本地失败'), findsOneWidget);
    expect(find.text('Unsaved'), findsOneWidget);
    fail = false;
    await tester.tap(find.byTooltip('保存到本地'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditorPage), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });
}
