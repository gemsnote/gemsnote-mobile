package com.github.gemsnote;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Bounded, strict text decoding shared by intent text and content-provider files. */
public final class SharedTextDecoder {
    public static final int MAX_BYTES = 256 * 1024;

    private SharedTextDecoder() {}

    public static String read(InputStream stream) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        while (true) {
            if (Thread.currentThread().isInterrupted()) throw new IOException("读取分享已取消");
            int read = stream.read(buffer, 0, Math.min(buffer.length, MAX_BYTES + 1 - bytes.size()));
            if (read < 0) break;
            if (read == 0) {
                int next = stream.read();
                if (next < 0) break;
                bytes.write(next);
            } else {
                bytes.write(buffer, 0, read);
            }
            if (bytes.size() > MAX_BYTES) throw new IOException("分享文本超过 256 KiB");
        }
        String text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
        if (text.startsWith("\uFEFF")) text = text.substring(1);
        return validate(text);
    }

    public static String validate(String text) throws IOException {
        if (text == null || text.isEmpty() || text.indexOf('\0') >= 0
                || text.codePoints().allMatch(c -> Character.isWhitespace(c)
                    || Character.isSpaceChar(c) || c == 0x85 || c == 0xFEFF)) {
            throw new IOException("分享内容必须为非空文本");
        }
        if (text.length() > MAX_BYTES || StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(text)).remaining() > MAX_BYTES) {
            throw new IOException("分享文本超过 256 KiB");
        }
        return text;
    }

    public static String title(String value) {
        if (value == null) return "";
        int count = value.codePointCount(0, value.length());
        return count <= 200 ? value : value.substring(0, value.offsetByCodePoints(0, 200));
    }
}
