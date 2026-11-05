package com.github.gemsnote;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

public final class SharedResourceStoreTest {
    private static final String FIRST = "507f1f77bcf86cd799439011";
    private static final String SECOND = "507f1f77bcf86cd799439012";
    interface Action { void run() throws Exception; }
    private static void fails(Action action) throws Exception {
        try { action.run(); } catch (IOException | IllegalArgumentException expected) { return; }
        throw new AssertionError("expected failure");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }

    public static void main(String[] args) throws Exception {
        File dir = Files.createTempDirectory("gemsnote-share-resources-").toFile();
        SharedResourceStore store = new SharedResourceStore(dir);
        try {
            byte[] payload = {1, 2, 3, 0, -1};
            check(store.write(FIRST, new ByteArrayInputStream(payload), () -> false) == payload.length);
            store.prune(Set.of()); // In-flight file not yet committed to preferences.
            check(Arrays.equals(store.read(FIRST, payload.length), payload));
            store.release(FIRST);
            SharedResourceStore reopened = new SharedResourceStore(dir);
            reopened.prune(Set.of(FIRST));
            check(Arrays.equals(reopened.read(FIRST, payload.length), payload));
            fails(() -> reopened.read(FIRST, 4));
            fails(() -> reopened.read("../escape", 1));
            fails(() -> reopened.delete("../escape"));
            fails(() -> reopened.write(FIRST, new ByteArrayInputStream(payload), () -> false));
            reopened.prune(Set.of()); // Unreferenced file from process death is reclaimable.
            check(!new File(dir, FIRST).exists());

            fails(() -> store.write(FIRST, new ByteArrayInputStream(new byte[0]), () -> false));
            fails(() -> store.write(FIRST, new ByteArrayInputStream(payload), () -> true));
            check(!new File(dir, FIRST).exists());
            InputStream oversized = new InputStream() {
                long left = SharedResourceStore.MAX_FILE + 1;
                @Override public int read() { return left-- > 0 ? 0 : -1; }
                @Override public int read(byte[] b) {
                    if (left <= 0) return -1;
                    int count = (int)Math.min(left, b.length);
                    left -= count;
                    return count;
                }
            };
            fails(() -> store.write(FIRST, oversized, () -> false));
            check(!new File(dir, FIRST).exists());
            try (RandomAccessFile quota = new RandomAccessFile(new File(dir, FIRST), "rw")) { quota.setLength(SharedResourceStore.MAX_TOTAL); }
            fails(() -> store.write(SECOND, new ByteArrayInputStream(payload), () -> false));
            check(!new File(dir, SECOND).exists());
            store.delete(FIRST);

            CountDownLatch reading = new CountDownLatch(1), proceed = new CountDownLatch(1);
            ExecutorService executor = Executors.newSingleThreadExecutor();
            try {
                Future<Long> pending = executor.submit(() -> store.write(FIRST, new ByteArrayInputStream(payload) {
                    @Override public synchronized int read(byte[] b) throws IOException {
                        reading.countDown();
                        try { if (!proceed.await(5, TimeUnit.SECONDS)) throw new IOException("timeout"); }
                        catch (InterruptedException e) { throw new IOException(e); }
                        return super.read(b);
                    }
                }, () -> false));
                check(reading.await(5, TimeUnit.SECONDS));
                store.prune(Set.of());
                proceed.countDown();
                check(pending.get(5, TimeUnit.SECONDS) == payload.length);
                check(Arrays.equals(store.read(FIRST, payload.length), payload));
                store.release(FIRST);
            } finally { executor.shutdownNow(); }
            System.out.println("SharedResourceStore tests passed");
        } finally {
            File[] files = dir.listFiles();
            if (files != null) for (File file : files) Files.deleteIfExists(file.toPath());
            Files.deleteIfExists(dir.toPath());
        }
    }
}
