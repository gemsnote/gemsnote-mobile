package com.github.gemsnote.sharefixture;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.util.Base64;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.List;

public final class FixtureProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }

    private File file(Uri uri) throws FileNotFoundException {
        List<String> parts = uri.getPathSegments();
        if (parts.size() != 2 || !parts.get(0).matches("[0-9a-f]{32}"))
            throw new FileNotFoundException("Invalid fixture URI");
        String name = parts.get(1);
        byte[] bytes;
        switch (name) {
            case "image.png":
                try (InputStream input = getContext().getAssets().open("image.png");
                     ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                    bytes = output.toByteArray();
                } catch (IOException error) { throw new FileNotFoundException(error.toString()); }
                break;
            case "data.bin": bytes = new byte[]{0, 1, 2, 127, (byte)128, (byte)255}; break;
            case "animation.gif":
                bytes = Base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", Base64.DEFAULT);
                break;
            case "body.txt":
                bytes = ("\ufeffShared file " + parts.get(0) + "\n正文 😀").getBytes(StandardCharsets.UTF_8);
                break;
            case "empty.bin": bytes = new byte[0]; break;
            default: throw new FileNotFoundException("Unknown fixture file");
        }
        File file = new File(getContext().getCacheDir(), parts.get(0) + "-" + name);
        // Each test URI has fixed bytes; avoid rewriting an already-open file.
        synchronized (FixtureProvider.class) {
            if (!file.exists()) {
                try (FileOutputStream output = new FileOutputStream(file)) { output.write(bytes); }
                catch (IOException error) { throw new FileNotFoundException(error.toString()); }
            }
        }
        return file;
    }

    @Override public String getType(Uri uri) {
        String name = uri.getLastPathSegment();
        if ("image.png".equals(name)) return "image/png";
        if ("animation.gif".equals(name)) return "image/gif";
        if ("body.txt".equals(name)) return "text/plain";
        return "application/octet-stream";
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        try {
            File file = file(uri);
            String[] columns = projection == null
                ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns);
            MatrixCursor.RowBuilder row = cursor.newRow();
            for (String column : columns) row.add(
                OpenableColumns.DISPLAY_NAME.equals(column) ? uri.getLastPathSegment()
                : OpenableColumns.SIZE.equals(column) ? file.length() : null);
            return cursor;
        } catch (FileNotFoundException error) { throw new IllegalArgumentException(error); }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read only");
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
