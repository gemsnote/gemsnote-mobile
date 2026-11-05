import 'dart:ui' show Locale;

import '../l10n/app_strings.dart';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'note_exporter.dart';

class AttachmentExporter {
  AttachmentExporter({
    SaveNoteFile? save,
    this.strings = const AppStrings(Locale('zh')),
  }) : _save =
           save ??
           (({required fileName, required bytes, required mimeType}) =>
               _saveSystem(
                 fileName: fileName,
                 bytes: bytes,
                 mimeType: mimeType,
                 dialogTitle: strings.label('保存附件'),
               ));
  final AppStrings strings;
  final SaveNoteFile _save;

  static Future<Uri?> _saveSystem({
    required String dialogTitle,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) => FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
    dialogTitle: dialogTitle,
  );

  Future<bool> save(String title, Uint8List bytes) async {
    if (bytes.length > 32 * 1024 * 1024) throw StateError('附件超过 32 MiB');
    return await _save(
          fileName: NoteExporter.safeFileName(
            title,
            '',
            fallback: strings.label('附件'),
          ),
          bytes: bytes,
          mimeType: 'application/octet-stream',
        ) !=
        null;
  }
}
