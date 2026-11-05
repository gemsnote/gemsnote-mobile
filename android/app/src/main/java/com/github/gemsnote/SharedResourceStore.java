package com.github.gemsnote;

import java.io.*;
import java.util.*;
import java.util.function.BooleanSupplier;

/** Private originals. No caller-supplied paths or provider names reach disk. */
public final class SharedResourceStore {
    public static final long MAX_FILE = 32L * 1024 * 1024;
    public static final long MAX_TOTAL = 96L * 1024 * 1024;
    private final File directory;
    private final Set<String> active = new HashSet<>();

    public SharedResourceStore(File directory) throws IOException {
        this.directory = directory;
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建分享暂存目录");
    }

    private File file(String id) {
        if (id == null || !id.matches("[0-9a-f]{24}")) throw new IllegalArgumentException("无效的分享 ID");
        return new File(directory, id);
    }

    public long write(String id, InputStream input, BooleanSupplier cancelled) throws IOException {
        final File target = file(id);
        synchronized (this) {
            if (target.exists() || !active.add(id)) throw new IOException("分享 ID 重复");
        }
        long size = 0;
        try (FileOutputStream output = new FileOutputStream(target)) {
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (cancelled.getAsBoolean()) throw new IOException("分享读取已取消");
                if (count == 0) continue;
                if (size + count > MAX_FILE) throw new IOException("分享附件不能超过 32 MiB");
                synchronized (this) {
                    long total = 0;
                    File[] files = directory.listFiles();
                    if (files == null) throw new IOException("无法读取分享暂存目录");
                    for (File existing : files) total += existing.length();
                    if (total + count > MAX_TOTAL) throw new IOException("分享暂存空间已满，请先处理待导入分享");
                    output.write(buffer, 0, count);
                }
                size += count;
            }
            if (size == 0 || cancelled.getAsBoolean()) throw new IOException("分享文件为空或读取已取消");
            output.getFD().sync();
            return size;
        } catch (IOException | RuntimeException failure) {
            delete(id);
            throw failure;
        }
    }

    public synchronized void release(String id) { active.remove(id); }

    public synchronized void delete(String id) throws IOException {
        File target = file(id);
        if (target.exists() && !target.delete()) throw new IOException("无法移除分享暂存文件");
        active.remove(id);
    }

    public synchronized void prune(Set<String> retained) throws IOException {
        File[] files = directory.listFiles();
        if (files == null) throw new IOException("无法读取分享暂存目录");
        for (File candidate : files) {
            String id = candidate.getName();
            if (id.matches("[0-9a-f]{24}") && !retained.contains(id) && !active.contains(id)) delete(id);
        }
    }

    public byte[] read(String id, long expectedSize) throws IOException {
        if (expectedSize <= 0 || expectedSize > MAX_FILE) throw new IOException("分享文件大小无效");
        File target = file(id);
        if (target.length() != expectedSize) throw new IOException("分享文件不完整，请重新分享");
        try (InputStream input = new FileInputStream(target)) {
            byte[] bytes = new byte[(int) expectedSize];
            int offset = 0;
            while (offset < bytes.length) {
                int count = input.read(bytes, offset, bytes.length - offset);
                if (count < 0) throw new IOException("分享文件不完整");
                offset += count;
            }
            if (input.read() != -1) throw new IOException("分享文件已变化");
            return bytes;
        }
    }
}
