import 'package:flutter/widgets.dart';

import 'app_bootstrap.dart';
import 'services/app_startup.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GemsnoteBootstrap(initialize: initializeApplication));
}
