import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/tag_choices.dart';

void main() {
  test('top ten are ranked by count; filtering searches all tags', () {
    final counts = {for (var i = 0; i < 15; i++) 'tag$i': 30 - i};
    expect(
      tagChoices(counts, limit: 10).map((e) => e.key),
      List.generate(10, (i) => 'tag$i'),
    );
    expect(tagChoices(counts, query: ' TAG14 ').single.key, 'tag14');
    expect(tagChoices(counts, query: 'tag'), hasLength(15));
    expect(tagChoices(counts, query: 'missing'), isEmpty);
  });
  test('ties are stable and empty, zero-count and selected tags excluded', () {
    final counts = {
      'beta': 1,
      'alpha': 1,
      'Alpha': 1,
      '': 8,
      ' ': 7,
      'zero': 0,
    };
    expect(tagChoices(counts).map((e) => e.key), ['Alpha', 'alpha', 'beta']);
    expect(tagChoices(counts, includeUnused: true).map((e) => e.key), [
      'Alpha',
      'alpha',
      'beta',
      'zero',
    ]);
    expect(tagChoices(counts, excluded: {'Alpha', 'alpha'}).single.key, 'beta');
    expect(
      tagChoices(Map.fromEntries(counts.entries.toList().reversed))
          .map((e) => e.key),
      ['Alpha', 'alpha', 'beta'],
    );
  });
}
