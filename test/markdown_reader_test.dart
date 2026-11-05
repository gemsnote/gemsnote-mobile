import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/ui/note_reader_page.dart';

void main() {
  const source =
      '# Heading\n\n**Bold** and `code`\n\n- item\n\n| A | B |\n| --- | --- |\n| one | two |';
  Widget reader(String content) => MaterialApp(
    home: NoteReaderPage(
      note: Note.fromJson({
        'NoteId': 'n',
        'Title': 'Title',
        'Content': content,
        'IsMarkdown': true,
      }),
      readOnly: true,
    ),
  );

  testWidgets('renders Markdown, switches source, and copies exact original', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(reader(source));
    expect(find.byType(Markdown), findsOneWidget);
    expect(tester.widget<Markdown>(find.byType(Markdown)).selectable, isTrue);
    expect(find.text('Heading'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.byTooltip('编辑'), findsNothing);
    await tester.tap(find.byTooltip('查看原文'));
    await tester.pumpAndSettle();
    expect(find.text(source), findsOneWidget);
    expect(find.byType(Markdown), findsNothing);
    await tester.tap(find.byTooltip('复制 Markdown 原文'));
    await tester.pumpAndSettle();
    expect(copied, source);
    await tester.tap(find.byTooltip('查看预览'));
    await tester.pumpAndSettle();
    expect(find.byType(Markdown), findsOneWidget);
  });

  testWidgets('images stay placeholders and links require explicit copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      reader(
        '![remote](https://example.test/a.png)\n\n![local](/private/a.png)\n\n[Example](https://example.test/path)',
      ),
    );
    expect(find.text('图片尚未缓存：remote'), findsOneWidget);
    expect(find.text('图片尚未缓存：local'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    // Invoke the renderer callback: no automatic external navigation occurs.
    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    markdown.onTapLink!('Example', 'https://example.test/path', '');
    await tester.pumpAndSettle();
    expect(find.text('链接地址'), findsOneWidget);
    expect(find.text('https://example.test/path'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('clipboard failures are visible without leaving reader', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(reader(source));
    await tester.tap(find.byTooltip('复制 Markdown 原文'));
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    expect(find.byType(NoteReaderPage), findsOneWidget);
  });
}
