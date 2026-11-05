package com.github.gemsnote

import android.os.Bundle
import io.flutter.embedding.android.FlutterFragment

/** Let the native loading overlay draw while the surface waits for Dart. */
class StartupFlutterFragment : FlutterFragment() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Also applied when FragmentManager restores this fragment after process death.
        requireArguments().putBoolean(ARG_SHOULD_DELAY_FIRST_ANDROID_VIEW_DRAW, false)
        super.onCreate(savedInstanceState)
    }
}
