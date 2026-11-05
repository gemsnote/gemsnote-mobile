import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/conflict_copy.dart';

void main() {
  test('basic HTML accepts plain formatting without changing the source', () {
    for (final source in [
      '',
      'text &amp; entities',
      '<p>你好<br><b>text</b></p>',
      '<ol><li>one</li></ol>',
      '<pre><code>&lt;img src="x"&gt;</code></pre>',
    ]) {
      expect(
        canCopyConflictBody(source, isMarkdown: false),
        isTrue,
        reason: source,
      );
    }
  });
  test('resources, attributes, active and ambiguous HTML remain unsupported', () {
    for (final source in [
      '<img src="/files/x">',
      '<a href="https://example.test">link</a>',
      '<div style="background:url(x)">body</div>',
      '<p class="image">body</p>',
      '<script>bad()</script>',
      '<iframe>body</iframe>',
      '<svg>body</svg>',
      '<video></video>',
      '<object></object>',
      '<!-- resource -->',
      '<p onclick="bad()">body</p>',
      '<div data-file-id="x">body</div>',
      '<b><i>broken</b></i>',
      '${List.filled(70, '<div>').join()}deep${List.filled(70, '</div>').join()}',
    ]) {
      expect(
        canCopyConflictBody(source, isMarkdown: false),
        isFalse,
        reason: source,
      );
    }
  });
  test('Markdown conservative rules are unchanged', () {
    expect(canCopyConflictBody('# text', isMarkdown: true), isTrue);
    expect(canCopyConflictBody('[link](x)', isMarkdown: true), isFalse);
    expect(canCopyConflictBody('<p>body</p>', isMarkdown: true), isFalse);
  });
}
