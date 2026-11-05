package com.github.gemsnote;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Standalone JVM regression tests; compiled against the production decoder. */
public final class SharedTextDecoderTest {
    private interface Action { void run() throws Exception; }
    private static void check(boolean condition, String name) {
        if (!condition) throw new AssertionError(name);
    }
    private static void rejects(Action action, String name) throws Exception {
        try { action.run(); } catch (IOException expected) { return; }
        throw new AssertionError("Expected rejection: " + name);
    }
    private static String read(byte[] data) throws IOException {
        return SharedTextDecoder.read(new ByteArrayInputStream(data));
    }

    public static void main(String[] args) throws Exception {
        String source = "# 中文\n**Markdown**\r\nhttps://example.test\n😀";
        check(read(source.getBytes(StandardCharsets.UTF_8)).equals(source), "source unchanged");
        check(read(("\uFEFF" + source).getBytes(StandardCharsets.UTF_8)).equals(source), "UTF-8 BOM");
        byte[] maximum = new byte[SharedTextDecoder.MAX_BYTES];
        Arrays.fill(maximum, (byte) 'a');
        check(read(maximum).length() == maximum.length, "exact byte limit");
        rejects(() -> read(Arrays.copyOf(maximum, maximum.length + 1)), "over limit");
        rejects(() -> SharedTextDecoder.validate("中".repeat(90000)), "multibyte limit");
        rejects(() -> SharedTextDecoder.validate("bad\uD800"), "unpaired surrogate");
        for (String value : new String[] {"", " \t\r\n", "\u0085\uFEFF\u00A0", "nul\0"}) {
            rejects(() -> SharedTextDecoder.validate(value), "empty or binary");
        }
        for (byte[] bytes : new byte[][] {
                {(byte) 0xC3}, {(byte) 0xC0, (byte) 0x80},
                {(byte) 0xFF, (byte) 0xFE, 65, 0}, {(byte) 0xED, (byte) 0xA0, (byte) 0x80}}) {
            rejects(() -> read(bytes), "strict UTF-8");
        }
        InputStream chunked = new ByteArrayInputStream(source.getBytes(StandardCharsets.UTF_8)) {
            @Override public synchronized int read(byte[] bytes, int start, int count) {
                return super.read(bytes, start, Math.min(1, count));
            }
        };
        check(SharedTextDecoder.read(chunked).equals(source), "split multibyte sequence");
        final int[] consumed = {0};
        InputStream endless = new InputStream() {
            @Override public int read() { consumed[0]++; return 'x'; }
        };
        rejects(() -> SharedTextDecoder.read(endless), "unknown-length provider");
        check(consumed[0] == SharedTextDecoder.MAX_BYTES + 1, "never reads beyond bound plus sentinel");
        InputStream broken = new InputStream() {
            @Override public int read() throws IOException { throw new IOException("provider unavailable"); }
        };
        rejects(() -> SharedTextDecoder.read(broken), "provider failure");
        Thread.currentThread().interrupt();
        rejects(() -> read(new byte[] {'x'}), "interrupted reader");
        Thread.interrupted();
        String title = SharedTextDecoder.title("😀".repeat(201));
        check(title.codePointCount(0, title.length()) == 200, "title limit counts code points");
        check(title.getBytes(StandardCharsets.UTF_8).length == 800, "no split surrogate");
        check(SharedTextDecoder.title(null).isEmpty(), "missing subject");
        System.out.println("PASS text preservation, UTF-8/BOM, byte bounds, failures, Unicode titles");
    }
}
