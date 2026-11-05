package com.github.gemsnote.sharefixture;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import java.util.ArrayList;

/** Separate test-only sender: URI access must cross the Android grant boundary. */
public final class SharingActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String run = getIntent().getStringExtra("fixture-run");
        if (run == null || !run.matches("[0-9a-f]{32}")) {
            finish();
            return;
        }
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        for (boolean invalid : new boolean[]{false, true}) {
            Button button = new Button(this);
            button.setAllCaps(false);
            button.setText(invalid ? "Share invalid batch" : "Share valid batch");
            button.setOnClickListener(view -> share(run, invalid));
            layout.addView(button);
        }
        setContentView(layout);
    }

    private void share(String run, boolean invalid) {
        String[] names = invalid
            ? new String[]{"image.png", "empty.bin"}
            : new String[]{"image.png", "data.bin", "animation.gif", "body.txt"};
        ArrayList<Uri> uris = new ArrayList<>();
        for (String name : names) {
            uris.add(Uri.parse("content://com.github.gemsnote.sharefixture.files/" + run + "/" + name));
        }
        Intent intent = new Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*");
        intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        intent.putExtra(Intent.EXTRA_TEXT, "Caption " + run);
        ClipData clip = ClipData.newUri(getContentResolver(), "Fixture files", uris.get(0));
        for (int i = 1; i < uris.size(); i++) clip.addItem(new ClipData.Item(uris.get(i)));
        intent.setClipData(clip);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(Intent.createChooser(intent, "Share fixture files"));
    }
}
