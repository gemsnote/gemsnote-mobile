import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/services/deep_links.dart';

void main() {
  const noteId = '0123456789abcdef01234567';
  test('parses account-bound custom and web links', () {
    final custom = DeepLinkTarget.parse(
      Uri.parse(
        'gemsnote://note/$noteId?server=https%3A%2F%2Fnotes.example%2Fbase%2F&user=user-1',
      ),
    );
    expect(custom?.kind, DeepLinkKind.note);
    expect(custom?.server, Uri.parse('https://notes.example/base/'));
    expect(custom?.userId, 'user-1');

    final web = DeepLinkTarget.parse(
      Uri.parse('https://notes.example/base/app/shared/$noteId?user=user-2'),
    );
    expect(web?.kind, DeepLinkKind.shared);
    expect(web?.server, Uri.parse('https://notes.example/base/'));
    expect(web?.userId, 'user-2');
  });

  test('rejects malformed, unbound, and credential-bearing links', () {
    expect(DeepLinkTarget.parse(Uri.parse('gemsnote://note/$noteId')), isNull);
    expect(
      DeepLinkTarget.parse(
        Uri.parse(
          'gemsnote://note/not-an-id?server=https%3A%2F%2Fnotes.example&user=u',
        ),
      ),
      isNull,
    );
    expect(
      DeepLinkTarget.parse(
        Uri.parse(
          'gemsnote://note/$noteId?server=https%3A%2F%2Fname%3Asecret%40notes.example&user=u',
        ),
      ),
      isNull,
    );
  });

  test('matches only the intended server and account', () {
    final target = DeepLinkTarget.parse(
      Uri.parse('https://notes.example/app/note/$noteId?user=user-1'),
    )!;
    expect(
      target.matches(Uri.parse('https://notes.example/'), 'user-1'),
      isTrue,
    );
    expect(
      target.matches(Uri.parse('https://other.example/'), 'user-1'),
      isFalse,
    );
    expect(
      target.matches(Uri.parse('https://notes.example/'), 'user-2'),
      isFalse,
    );
  });

  test('retains a cold-start link until the workspace acknowledges it', () async {
    final stream = StreamController<Uri>();
    addTearDown(stream.close);
    final target = Uri.parse(
      'gemsnote://note/$noteId?server=https%3A%2F%2Fnotes.example&user=user-1',
    );
    final controller = DeepLinkController(
      initialLink: () async => target,
      links: stream.stream,
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.pending?.noteId, noteId);
    final pending = controller.pending!;
    controller.acknowledge(pending);
    expect(controller.pending, isNull);
  });
}
