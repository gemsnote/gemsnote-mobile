import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/core/api/api2_client.dart';
import 'package:gemsnote/core/api/api_exception.dart';
import 'package:gemsnote/core/async/cancellation.dart';
import 'package:gemsnote/l10n/app_strings.dart';
import 'package:http/http.dart' as http;

class StreamingClient extends http.BaseClient {
  StreamingClient(this.respond);
  final Future<http.StreamedResponse> Function(http.AbortableRequest) respond;
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    return respond(request as http.AbortableRequest);
  }
}

void main() {
  final server = Uri.parse('https://notes.example.test');

  test('slow note body uses its own budget and smaller page', () async {
    final transport = StreamingClient((request) async {
      expect(request.url.path, '/api2/note/getSyncNotesWithContent');
      expect(request.url.queryParameters['maxEntry'], '10');
      expect(request.url.queryParameters['afterUsn'], '7');
      return http.StreamedResponse(() async* {
        yield utf8.encode('[{"NoteId":"note","Content":"');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        yield utf8.encode('complete body","Usn":8}]');
      }(), 200);
    });
    final api = Api2Client(
      httpClient: transport,
      requestTimeout: const Duration(milliseconds: 10),
      noteContentTimeout: const Duration(seconds: 2),
    );
    final notes = await api.getNotesWithContent(
      server: server,
      token: 'test-token',
      afterUsn: 7,
    );
    expect(notes.single.content, 'complete body');
    expect(transport.requests, 1);
  });

  for (final bodyStarted in [false, true]) {
    test(
      'timeout aborts ${bodyStarted ? 'body' : 'headers'} without retrying login',
      () async {
        final aborted = Completer<void>();
        final transport = StreamingClient((request) async {
          request.abortTrigger!.then((_) => aborted.complete());
          if (!bodyStarted) return Completer<http.StreamedResponse>().future;
          final body = StreamController<List<int>>();
          request.abortTrigger!.then((_) {
            body.addError(http.RequestAbortedException(request.url));
            body.close();
          });
          body.add(utf8.encode('[{"Content":"unfinished'));
          return http.StreamedResponse(body.stream, 200);
        });
        final api = Api2Client(
          httpClient: transport,
          requestTimeout: const Duration(milliseconds: 30),
          noteContentTimeout: const Duration(milliseconds: 30),
        );
        final task = bodyStarted
            ? api.getNotesWithContent(
                server: server,
                token: 'test-token',
                afterUsn: 0,
              )
            : api.login(
                server: server,
                identity: 'reader',
                password: 'fixture-password',
              );
        await expectLater(
          task,
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              bodyStarted ? 'noteDownloadTimedOut' : 'requestTimedOut',
            ),
          ),
        );
        await aborted.future.timeout(const Duration(seconds: 1));
        expect(transport.requests, 1);
      },
    );
  }

  test(
    'cancel remains cancellation rather than a timeout or network error',
    () async {
      final started = Completer<void>();
      final aborted = Completer<void>();
      final api = Api2Client(
        httpClient: StreamingClient((request) {
          started.complete();
          request.abortTrigger!.then((_) => aborted.complete());
          return Completer<http.StreamedResponse>().future;
        }),
      );
      final cancel = Cancellation();
      final task = cancel.run(
        () => api.getNotesWithContent(
          server: server,
          token: 'test-token',
          afterUsn: 0,
        ),
      );
      final assertion = expectLater(task, throwsA(isA<SyncCancelled>()));
      await started.future;
      cancel.cancel();
      await assertion;
      await aborted.future.timeout(const Duration(seconds: 1));
    },
  );

  test('timeout messages distinguish connectivity and body transfer in both languages', () {
    for (final language in ['zh', 'en']) {
      final strings = AppStrings(Locale(language));
      final timeout = strings.errorMessage(
        const ApiException('noteDownloadTimedOut'),
      );
      expect(
        timeout,
        isNot(strings.errorMessage(const ApiException('networkUnavailable'))),
      );
      expect(
        timeout,
        contains(language == 'zh' ? '正文下载超时' : 'note bodies timed out'),
      );
      expect(
        strings.errorMessage(const ApiException('requestTimedOut')),
        contains(language == 'zh' ? '响应超时' : 'response timed out'),
      );
    }
  });
}
