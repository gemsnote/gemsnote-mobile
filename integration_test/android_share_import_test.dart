import 'dart:io';

import 'native_share_import_scenario.dart' as scenario;

void main() => scenario.runShareImport(supported: Platform.isAndroid);
