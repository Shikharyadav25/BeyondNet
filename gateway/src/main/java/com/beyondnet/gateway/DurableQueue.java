package com.beyondnet.gateway;

import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.*;
import java.util.*;

/** Stores opaque ciphertext. Caller must authenticate the peer before invoking offer. */
public final class DurableQueue implements AutoCloseable {
  private final Connection db;
  private final int totalLimit, userLimit;

  public DurableQueue(Path path, int totalLimit, int userLimit) throws SQLException {
    if (totalLimit < 1 || userLimit < 1 || userLimit > totalLimit)
      throw new IllegalArgumentException();
    this.totalLimit = totalLimit;
    this.userLimit = userLimit;
    db = DriverManager.getConnection("jdbc:sqlite:" + path.toAbsolutePath());
    try (var s = db.createStatement()) {
      s.execute("PRAGMA journal_mode=WAL");
      s.execute("PRAGMA synchronous=FULL");
      s.execute("PRAGMA busy_timeout=5000");
      s.execute(
          "CREATE TABLE IF NOT EXISTS queue(id TEXT PRIMARY KEY,owner TEXT NOT NULL,kind TEXT NOT"
              + " NULL,hash TEXT NOT NULL,payload BLOB NOT NULL,expires INTEGER NOT NULL,state TEXT"
              + " NOT NULL DEFAULT 'queued',attempts INTEGER NOT NULL DEFAULT 0,next_attempt"
              + " INTEGER NOT NULL DEFAULT 0,result BLOB)");
      s.execute("CREATE INDEX IF NOT EXISTS queue_due ON queue(kind,state,next_attempt)");
    }
  }

  static String hash(byte[] bytes) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    } catch (Exception e) {
      throw new IllegalStateException(e);
    }
  }

  long scalar(String sql, String... args) throws SQLException {
    try (var s = db.prepareStatement(sql)) {
      for (int i = 0; i < args.length; i++) s.setString(i + 1, args[i]);
      try (var r = s.executeQuery()) {
        r.next();
        return r.getLong(1);
      }
    }
  }

  public synchronized boolean offer(
      String id, String owner, String kind, byte[] payload, long expires, long now)
      throws SQLException {
    if (id == null
        || id.isBlank()
        || id.length() > 100
        || owner == null
        || owner.isBlank()
        || owner.length() > 100
        || !Set.of("payment", "interactive", "background").contains(kind)
        || payload.length == 0
        || payload.length > (kind.equals("payment") ? 8192 : 4096)
        || expires <= now
        || expires > now + (kind.equals("payment") ? 600 : 86400))
      throw new IllegalArgumentException("Invalid queue item");
    db.setAutoCommit(false);
    try {
      try (var s = db.prepareStatement("SELECT owner,kind,hash,expires FROM queue WHERE id=?")) {
        s.setString(1, id);
        try (var rows = s.executeQuery()) {
          if (rows.next()) {
            if (!owner.equals(rows.getString(1))
                || !kind.equals(rows.getString(2))
                || !hash(payload).equals(rows.getString(3))
                || expires != rows.getLong(4))
              throw new IllegalArgumentException("Conflicting request ID");
            db.commit();
            return false;
          }
        }
      }
      // Independent class budgets prevent background requests from consuming payment capacity.
      if (scalar("SELECT COUNT(*) FROM queue WHERE kind=?", kind) >= totalLimit
          || scalar("SELECT COUNT(*) FROM queue WHERE kind=? AND owner=?", kind, owner)
              >= userLimit)
        throw new IllegalStateException("Storage quota reached; custody refused");
      try (var s =
          db.prepareStatement(
              "INSERT INTO queue(id,owner,kind,hash,payload,expires) VALUES(?,?,?,?,?,?)")) {
        s.setString(1, id);
        s.setString(2, owner);
        s.setString(3, kind);
        s.setString(4, hash(payload));
        s.setBytes(5, payload);
        s.setLong(6, expires);
        s.executeUpdate();
      }
      db.commit();
      return true;
    } catch (Exception e) {
      db.rollback();
      throw e;
    } finally {
      db.setAutoCommit(true);
    }
  }

  public record Item(String id, byte[] payload, long expires, int attempts) {}

  public synchronized Item next(String kind, long now) throws SQLException {
    try (var s =
        db.prepareStatement(
            "SELECT id,payload,expires,attempts FROM queue WHERE kind=? AND state='queued' AND"
                + " next_attempt<=? ORDER BY next_attempt,id LIMIT 1")) {
      s.setString(1, kind);
      s.setLong(2, now);
      try (var r = s.executeQuery()) {
        return r.next() ? new Item(r.getString(1), r.getBytes(2), r.getLong(3), r.getInt(4)) : null;
      }
    }
  }

  public synchronized void retry(Item item, long now) throws SQLException {
    try (var s =
        db.prepareStatement(
            "UPDATE queue SET attempts=attempts+1,next_attempt=? WHERE id=? AND state='queued'")) {
      s.setLong(1, now + Math.min(300, 1L << Math.min(8, item.attempts() + 1)));
      s.setString(2, item.id());
      s.executeUpdate();
    }
  }

  public synchronized void finish(String id, byte[] result) throws SQLException {
    if (result.length > 12288) throw new IllegalArgumentException("Result exceeds limit");
    try (var s = db.prepareStatement("UPDATE queue SET state='result',result=? WHERE id=?")) {
      s.setBytes(1, result);
      s.setString(2, id);
      s.executeUpdate();
    }
  }

  public synchronized byte[] result(String id, String owner) throws SQLException {
    try (var s = db.prepareStatement("SELECT result FROM queue WHERE id=? AND owner=?")) {
      s.setString(1, id);
      s.setString(2, owner);
      try (var r = s.executeQuery()) {
        return r.next() ? r.getBytes(1) : null;
      }
    }
  }

  // Never delete an unresolved payment merely because its authorization expired.
  @Override
  public synchronized void close() throws SQLException {
    db.close();
  }
}
