package com.github.gemsnote.sharefixture;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Test-only, local receiver. No network/storage permissions or external sends. */
public final class ReceivingActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        JSONObject record = new JSONObject();
        try {
            Intent intent = getIntent();
            record.put("action", intent.getAction());
            record.put("type", intent.getType());
            record.put("text", intent.getStringExtra(Intent.EXTRA_TEXT));
            record.put("subject", intent.getStringExtra(Intent.EXTRA_SUBJECT));
            Uri stream = Intent.ACTION_VIEW.equals(intent.getAction())
                ? intent.getData() : intent.getParcelableExtra(Intent.EXTRA_STREAM);
            record.put("hasStream", stream != null);
            if (stream != null) {
                record.put("scheme", stream.getScheme());
                record.put("readGrant",
                    (intent.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0);
                try (Cursor cursor = getContentResolver().query(
                        stream, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) record.put("name", cursor.getString(0));
                }
                try (InputStream input = getContentResolver().openInputStream(stream);
                     ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[4096];
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        if (output.size() + count > 1024 * 1024) {
                            throw new IllegalStateException("Fixture exceeds 1 MiB");
                        }
                        output.write(buffer, 0, count);
                    }
                    record.put("bytes", Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP));
                }
            }
        } catch (Exception error) {
            try { record.put("error", error.toString()); } catch (Exception ignored) {}
        }
        try (FileOutputStream output = openFileOutput("received.jsonl", MODE_APPEND)) {
            output.write((record.toString() + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) {
            throw new IllegalStateException(error);
        }
        finish();
    }
}
