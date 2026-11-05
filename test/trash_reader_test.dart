import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_reader_page.dart';

void main() {
  for (final trash in [false, true]) {
    testWidgets('permanent delete is offered only in trash: $trash', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NoteReaderPage(
            note: Note.fromJson({
              'Title': 'Note',
              'Content': 'body',
              'IsMarkdown': true,
              'IsTrash': trash,
            }),
            onDeleteForever: () async {
              calls++;
              return false;
            },
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('彻底删除'), trash ? findsOneWidget : findsNothing);
      if (trash) {
        await tester.tap(find.text('彻底删除'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(
          find.byType(NoteReaderPage),
          findsOneWidget,
        ); // Cancel retains reader.
      }
    });
  }
}
