import 'package:flutter_test/flutter_test.dart';

import 'package:gemsnote/ui/visual_html_editor.dart';

void main() {
  test('visual editor accepts basic offline formatting', () {
    for (final source in [
      '',
      '<p>Hello <b>world</b></p>',
      '<h2>标题</h2><ol><li>条目</li></ol>',
      '<p><a href="https://example.com/path?q=a&amp;b=c">链接</a></p>',
    ]) {
      expect(supportsVisualHtml(source), isTrue);
      expect(visualEditorDocument(source), contains('window.readContent'));
    }
  });
  test('complex and active markup stays in source editor', () {
    for (final source in [
      '<script>alert(1)</script>',
      '<p onclick="alert(1)">a</p>',
      '<iframe></iframe>',
      '<p style="background:url(https://host/a)">a</p>',
      '<a href="javascript:alert(1)">a</a>',
    ]) {
      expect(supportsVisualHtml(source), isFalse);
      expect(() => visualEditorDocument(source), throwsArgumentError);
    }
  });
  test('document is network isolated and original source is retained', () {
    final document = visualEditorDocument('<p>你好 &lt;/script&gt;</p>');
    expect(document, contains("connect-src 'none'"));
    expect(document, contains("img-src data:"));
    expect(document, contains(r'\u003cp>'));
    expect(document, contains('changed ? editor.innerHTML : original'));
    expect(document, contains("getData('text/plain')"));
  });
}
