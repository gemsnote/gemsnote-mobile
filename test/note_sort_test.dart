import 'package:flutter/material.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/domain/models/note_sort.dart';

void main() {
  Note note(String id, String title, String time) =>
      Note.fromJson({'NoteId': id, 'Title': title, 'UpdatedTime': time});
  test('title sorting ignores case and breaks ties with stable server ID', () {
    final notes = [
      note('c', 'Beta', ''),
      note('b', 'alpha', ''),
      note('a', 'ALPHA', ''),
    ];
    expect(NoteSort.titleAscending.apply(notes).map((n) => n.noteId), [
      'a',
      'b',
      'c',
    ]);
    expect(NoteSort.titleDescending.apply(notes).map((n) => n.noteId), [
      'c',
      'a',
      'b',
    ]);
    expect(notes.first.noteId, 'c'); // Do not mutate the loaded snapshot.
    expect(NoteSort.titleAscending.apply(notes.reversed).map((n) => n.noteId), [
      'a',
      'b',
      'c',
    ]);
  });
  test('time sorting respects offsets and puts invalid dates last', () {
    final notes = [
      note('a', '', '2026-01-01T09:00:00+08:00'),
      note('b', '', '2026-01-01T02:00:00Z'),
      note('c', '', ''),
      note('d', '', 'bad-date'),
    ];
    expect(NoteSort.updatedAscending.apply(notes).map((n) => n.noteId), [
      'a',
      'b',
      'c',
      'd',
    ]);
    expect(NoteSort.updatedDescending.apply(notes).map((n) => n.noteId), [
      'b',
      'a',
      'c',
      'd',
    ]);
  });
  test('creation sorting uses creation dates, offsets, stable IDs and missing dates', () {
    final notes = [
      Note.fromJson({
        'NoteId': 'b',
        'CreatedTime': '2020-01-01T02:00:00Z',
        'UpdatedTime': '2026-01-01',
      }),
      Note.fromJson({
        'NoteId': 'c',
        'CreatedTime': '2020-01-01T09:00:00+08:00',
        'UpdatedTime': '2026-03-01',
      }),
      Note.fromJson({
        'NoteId': 'a',
        'CreatedTime': '2020-01-01T02:00:00Z',
        'UpdatedTime': '2026-02-01',
      }),
      Note.fromJson({'NoteId': 'd', 'CreatedTime': ''}),
      Note.fromJson({'NoteId': 'e', 'CreatedTime': 'bad-date'}),
    ];
    expect(NoteSort.createdAscending.apply(notes).map((n) => n.noteId), [
      'c',
      'a',
      'b',
      'd',
      'e',
    ]);
    expect(NoteSort.createdDescending.apply(notes).map((n) => n.noteId), [
      'a',
      'b',
      'c',
      'd',
      'e',
    ]);
    expect(
      NoteSort.createdAscending.apply(notes.reversed).map((n) => n.noteId),
      ['c', 'a', 'b', 'd', 'e'],
    );
    expect(notes.first.noteId, 'b');
    const english = AppStrings(Locale('en'));
    expect(
      english.label(NoteSort.createdAscending.label),
      'Created: oldest first',
    );
    expect(
      english.label(NoteSort.createdDescending.label),
      'Created: newest first',
    );
  });
  test(
    'equal times have the same deterministic order after a shuffled sync',
    () {
      final notes = [note('b', '', '2026-01-01'), note('a', '', '2026-01-01')];
      for (final sort in NoteSort.values) {
        expect(sort.apply(notes).map((n) => n.noteId), ['a', 'b']);
        expect(sort.apply(notes.reversed).map((n) => n.noteId), ['a', 'b']);
        expect(sort.apply([]), isEmpty);
      }
    },
  );
}
