import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemsnote/ui/visual_html_editor.dart';

void main() {
  final browser = Platform.environment['VISUAL_EDITOR_BROWSER'];
  test(
    'Chromium executes visual image insertion, undo and cache presentation without changing source',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'gemsnote-visual-browser-',
      );
      const oldImage = '/api2/file/getImage?fileId=507f1f77bcf86cd799439011';
      final data =
          'data:image/png;base64,${base64Encode(File('assets/images/gemsnote_s.png').readAsBytesSync())}';
      const source =
          '<p>beforeafter</p><p><img src="$oldImage" alt="cached"></p><img src="http://127.0.0.1:9/blocked.png" alt="uncached">';
      var document = visualEditorDocument(
        source,
        cachedImages: {oldImage: data},
      );
      document = document.replaceFirst('<script>', r'''<script>
window.Changes = {postMessage: value => window.lastChanged = value};
window.EditorError = {postMessage: value => {throw new Error(value)}};
window.blocked = [];
document.addEventListener('securitypolicyviolation', event => window.blocked.push(event.blockedURI));
''');
      document = document.replaceFirst('</body>', r'''
<pre id="test-result">not run</pre><script>
window.addEventListener('load', async () => {
  const report = document.getElementById('test-result');
  function check(value, message) { if (!value) throw new Error(message); }
  try {
    await new Promise(resolve => setTimeout(resolve, 100));
    check(window.readContent() === original, 'unchanged source was rewritten');
    const oldImage = editor.querySelector('img');
    check(getComputedStyle(oldImage).content.includes('data:image/png;base64,'), 'cached CSS replacement missing');
    check(oldImage.getAttribute('src') === '/api2/file/getImage?fileId=507f1f77bcf86cd799439011', 'preview changed original src');
    const oldCount = editor.querySelectorAll('img').length;
    const selection = window.getSelection();
    const range = document.createRange();
    range.setStart(editor.querySelector('p').firstChild, 0);
    range.setEnd(editor.querySelector('p').firstChild, 6);
    selection.removeAllRanges(); selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
    const newImage = '/api2/file/getImage?fileId=507f1f77bcf86cd799439012';
    window.cacheImage(newImage, cachedImages.values().next().value);
    window.insertImage(newImage);
    check(editor.querySelector('p').textContent === 'beforeafter', 'selection text lost');
    check(editor.querySelector('p').innerHTML.startsWith('before<img'), 'image not inserted after selection');
    check(editor.querySelectorAll('img').length === oldCount + 1, 'image insertion failed');
    check(!window.readContent().includes('data:image'), 'presentation bytes leaked into body');
    window.format('undo');
    check(editor.querySelectorAll('img').length === oldCount, 'undo failed');
    window.format('redo');
    check(editor.querySelectorAll('img').length === oldCount + 1, 'redo failed');
    const beforeInvalid = window.readContent();
    window.insertImage('https://outside.test/file');
    check(window.readContent() === beforeInvalid, 'invalid upload reference accepted');
    check(window.blocked.some(uri => uri.includes('127.0.0.1')), 'external image not blocked by CSP');
    check(window.lastChanged === window.readContent(), 'bridge does not match saved body');
    report.textContent = JSON.stringify({ok:true,content:window.readContent(),blocked:window.blocked});
  } catch (error) { report.textContent = JSON.stringify({ok:false,error:String(error),stack:error.stack}); }
});
</script></body>''');
      final file = File('${temp.path}/editor.html');
      await file.writeAsString(document);
      Process? process;
      WebSocket? socket;
      StreamSubscription<dynamic>? subscription;
      final pending = <int, Completer<Map<String, dynamic>>>{};
      var sequence = 0;
      Future<Map<String, dynamic>> call(
        String method,
        Map<String, Object?> params, {
        String? session,
      }) async {
        final id = ++sequence;
        final reply = Completer<Map<String, dynamic>>();
        pending[id] = reply;
        socket!.add(
          jsonEncode({
            'id': id,
            'method': method,
            'params': params,
            'sessionId': ?session,
          }),
        );
        try {
          return await reply.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw StateError('Browser command timed out: $method'),
          );
        } finally {
          pending.remove(id);
        }
      }

      final errors = StringBuffer();
      try {
        process = await Process.start(browser!, [
          '--headless=new',
          if (browser.contains('Vivaldi')) '--disable-vivaldi',
          '--disable-gpu',
          '--disable-background-networking',
          '--disable-component-update',
          '--no-first-run',
          '--no-default-browser-check',
          '--remote-debugging-port=0',
          '--user-data-dir=${temp.path}/profile',
          'about:blank',
        ]);
        process.stdout.drain<void>();
        process.stderr.transform(utf8.decoder).listen(errors.write);
        final portFile = File('${temp.path}/profile/DevToolsActivePort');
        for (
          var attempt = 0;
          attempt < 100 && !await portFile.exists();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!await portFile.exists()) {
          throw StateError('Browser debugging unavailable: $errors');
        }
        final address = await portFile.readAsLines();
        socket = await WebSocket.connect(
          'ws://127.0.0.1:${address[0]}${address[1]}',
        );
        subscription = socket.listen((raw) {
          final value = Map<String, dynamic>.from(
            jsonDecode(raw as String) as Map,
          );
          final reply = pending[value['id']];
          if (reply == null || reply.isCompleted) return;
          if (value['error'] != null) {
            reply.completeError(StateError('${value['error']}'));
          } else {
            reply.complete(Map<String, dynamic>.from(value['result'] as Map));
          }
        });
        final target = await call('Target.createTarget', {
          'url': file.uri.toString(),
        });
        final attached = await call('Target.attachToTarget', {
          'targetId': target['targetId'],
          'flatten': true,
        });
        final sessionId = attached['sessionId'] as String;
        String? result;
        for (var attempt = 0; attempt < 100; attempt++) {
          final value = await call('Runtime.evaluate', {
            'expression': "document.getElementById('test-result')?.textContent",
            'returnByValue': true,
          }, session: sessionId);
          result = (value['result'] as Map)['value'] as String?;
          if (result != null && result != 'not run') break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(result, isNotNull, reason: '$errors');
        expect(result, isNot('not run'), reason: '$errors');
        final report = jsonDecode(result!) as Map;
        expect(report['ok'], true, reason: '$report');
        expect(supportsVisualHtml(report['content'] as String), true);
      } finally {
        if (socket != null) {
          try {
            await call('Browser.close', {});
          } on Object {
            /* Already closed. */
          }
          await subscription?.cancel();
          await socket.close();
        }
        process?.kill();
        if (process != null) {
          await process.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              process!.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        }
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
    skip: browser == null
        ? 'Set VISUAL_EDITOR_BROWSER to an installed Chromium executable for this opt-in runtime check.'
        : false,
  );
}
