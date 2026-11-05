import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/domain/models/account.dart';
import 'package:gemsnote/domain/models/note.dart';
import 'package:gemsnote/repositories/auth_repository.dart';
import 'package:gemsnote/services/home_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/home_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  StoredSession session(String id) => StoredSession(
    account: Account(
      userId: id,
      server: Uri.parse('https://example.test/'),
      username: id,
      email: '',
      logo: '',
    ),
    token: 'private-token',
  );
  Note note(
    int id, {
    String title = 'title',
    bool trash = false,
    bool deleted = false,
  }) => Note.fromJson({
    'NoteId': id.toRadixString(16).padLeft(24, '0'),
    'Title': title,
    'Content': 'secret body',
    'UpdatedTime': id.toString().padLeft(4, '0'),
    'IsTrash': trash,
    'IsDeleted': deleted,
  });
  late HomeWidgetController controller;
  final publications = <Map>[];
  final preferences = <String, bool>{};
  var account = '', epoch = '', fail = false;
  Map<String, String>? pending;
  var generation = 0;
  setUp(() {
    publications.clear();
    preferences.clear();
    account = '';
    epoch = '';
    fail = false;
    pending = null;
    generation = 0;
    controller = HomeWidgetController(channel: channel, supported: true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (fail) throw PlatformException(code: 'disk');
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'activate':
          account = args['account'] as String;
          epoch = '${++generation}';
          return {'epoch': epoch, 'enabled': preferences[account] ?? false};
        case 'publish':
          expect(args['account'], account);
          expect(args['epoch'], epoch);
          publications.add(args);
          return null;
        case 'setEnabled':
          expect(args['account'], account);
          expect(args['epoch'], epoch);
          preferences[account] = args['enabled'] as bool;
          return null;
        case 'peek':
          return pending;
        case 'acknowledge':
          if (pending?['id'] == args['id']) pending = null;
          return null;
      }
      throw StateError('Unexpected method ${call.method}');
    });
  });
  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'snapshots contain only bounded titles and IDs, excluding trash and bodies',
    () {
      final result = HomeWidgetController.snapshot([
        for (var i = 0; i < 40; i++) note(i),
        note(999, trash: true),
        note(998, deleted: true),
      ]);
      expect(result.length, 30);
      expect(result.first['id'], note(39).noteId);
      expect(result.last['id'], note(10).noteId);
      expect(result.every((item) => item.keys.length == 2), isTrue);
      expect(result.toString(), isNot(contains('secret')));
      final title = HomeWidgetController.snapshot([
        note(1, title: '\n${List.filled(200, '😀').join()}'),
      ]).single['title']!;
      expect(title.runes.length, 160);
      expect(title, isNot(contains('\n')));
    },
  );
  test('titles stay private until explicit enable; disabled widget never reads notes', () async {
    var reads = 0;
    Future<List<Note>> load() async {
      reads++;
      return [note(1)];
    }

    await controller.activate(session('a'), load);
    expect(reads, 0);
    expect(publications, isEmpty);
    await controller.setEnabled(true, load);
    expect(reads, 1);
    expect(publications.length, 1);
    await controller.setEnabled(false, load);
    await controller.refresh(account, load);
    expect(reads, 1);
    expect(controller.enabled, isFalse);
  });
  test('logout does not wait for a slow account read or allow its late publication', () async {
    preferences[session('a').account.cacheKey] = true;
    final gate = Completer<List<Note>>();
    final readStarted = Completer<void>();
    final first = controller.activate(session('a'), () {
      readStarted.complete();
      return gate.future;
    });
    await readStarted.future;
    await controller.activate(null, null);
    expect(account, '');
    expect(controller.enabled, isFalse);
    gate.complete([note(1)]);
    await first;
    expect(publications, isEmpty);
  });
  test(
    'switch isolates preferences and rejects refresh from old account',
    () async {
      preferences[session('a').account.cacheKey] = true;
      await controller.activate(session('a'), () async => [note(1)]);
      await controller.activate(session('b'), () async => [note(2)]);
      expect(controller.enabled, isFalse);
      await controller.refresh(
        session('a').account.cacheKey,
        () async => [note(3)],
      );
      expect(publications, hasLength(1));
      await controller.setEnabled(true, () async => [note(2)]);
      expect(publications.last['account'], session('b').account.cacheKey);
    },
  );
  test('older overlapping reads cannot replace newer snapshots', () async {
    preferences[session('a').account.cacheKey] = true;
    await controller.activate(session('a'), null);
    final gate = Completer<List<Note>>();
    final first = controller.refresh(account, () => gate.future);
    await controller.refresh(account, () async => [note(2)]);
    gate.complete([note(1)]);
    await first;
    expect(publications, hasLength(1));
    expect((publications.single['notes'] as List).single['id'], note(2).noteId);
  });
  test('failed native setting does not silently enable and initialization can retry', () async {
    fail = true;
    await controller.activate(session('a'), null);
    expect(controller.ready, isFalse);
    expect(controller.error, isNotNull);
    fail = false;
    await controller.activate(session('a'), null);
    expect(controller.ready, isTrue);
    fail = true;
    await expectLater(
      controller.setEnabled(true, () async => [note(1)]),
      throwsA(isA<PlatformException>()),
    );
    expect(controller.enabled, isFalse);
  });
  test(
    'actions validate type and ID and acknowledge only the handled entry',
    () async {
      await controller.activate(session('a'), null);
      pending = {
        'id': 'one',
        'account': account,
        'action': 'open',
        'noteId': note(1).noteId,
      };
      await controller.peek();
      final action = controller.pending!;
      pending = {...pending!, 'id': 'two'};
      await controller.acknowledge(action);
      expect(pending!['id'], 'two');
      await controller.peek();
      expect(controller.pending!.id, 'two');
      expect(
        () => HomeWidgetAction.fromMap({
          'id': 'x',
          'account': account,
          'action': 'delete',
        }),
        throwsFormatException,
      );
      expect(
        () => HomeWidgetAction.fromMap({
          'id': 'x',
          'account': account,
          'action': 'open',
          'noteId': '../note',
        }),
        throwsFormatException,
      );
    },
  );
  test('unsupported platforms never contact native APIs', () async {
    controller.dispose();
    controller = HomeWidgetController(channel: channel, supported: false);
    fail = true;
    await controller.activate(session('a'), () async => [note(1)]);
    expect(generation, 0);
    expect(publications, isEmpty);
  });
}
