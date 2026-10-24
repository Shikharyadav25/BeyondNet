package com.beyondnet.campus;

import static com.beyondnet.campus.contract.SignedContent.*;

import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.*;
import java.sql.*;
import java.time.Instant;
import java.util.*;

/** Local provisioning tool. Credentials go to private files, never command output. */
public final class CampusAdmin {
  static void privateFile(Path p, byte[] bytes) throws Exception {
    Files.createDirectories(p.toAbsolutePath().getParent());
    Files.createFile(
        p, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
    Files.write(p, bytes);
  }

  public static void main(String[] args) throws Exception {
    if (args.length < 2)
      throw new IllegalArgumentException(
          "Commands: keys DIRECTORY | enroll ID OUTPUT_FILE | revoke ID | publish RECORDS_JSON");
    if (args[0].equals("keys")) {
      Path dir = Path.of(args[1]);
      Files.createDirectories(dir);
      if (Files.exists(dir.resolve("publisher.pk8")) || Files.exists(dir.resolve("publisher.der")))
        throw new IllegalStateException("Publisher exists; refusing to overwrite trust");
      var pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair();
      privateFile(dir.resolve("publisher.pk8"), pair.getPrivate().getEncoded());
      privateFile(dir.resolve("publisher.der"), pair.getPublic().getEncoded());
      Files.writeString(
          dir.resolve("publisher-public.txt"),
          Base64.getEncoder().encodeToString(pair.getPublic().getEncoded()) + "\n");
      return;
    }
    try (var db =
        DriverManager.getConnection(
            System.getenv("CAMPUS_DB_URL"),
            System.getenv("CAMPUS_DB_USER"),
            System.getenv("CAMPUS_DB_PASSWORD"))) {
      if (args[0].equals("enroll")) {
        if (args.length != 3 || !args[1].matches("[A-Za-z0-9@._-]{1,100}"))
          throw new IllegalArgumentException("Invalid enrollment");
        byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(random);
        // Write first; a failed insert leaves a useless token, never an unrecorded active
        // credential.
        privateFile(Path.of(args[2]), token.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        try (var s =
            db.prepareStatement(
                "INSERT INTO campus_principals(id,token_hash,expires_at) VALUES(?,?,?) ON"
                    + " CONFLICT(id) DO UPDATE SET"
                    + " token_hash=excluded.token_hash,expires_at=excluded.expires_at,revoked=FALSE")) {
          s.setString(1, args[1]);
          s.setString(2, hash(token));
          s.setLong(3, Instant.now().getEpochSecond() + 30L * 86400);
          s.executeUpdate();
        }
      } else if (args[0].equals("revoke")) {
        try (var s = db.prepareStatement("UPDATE campus_principals SET revoked=TRUE WHERE id=?")) {
          s.setString(1, args[1]);
          s.executeUpdate();
        }
      } else if (args[0].equals("publish")) {
        byte[] raw = Files.readAllBytes(Path.of(args[1]));
        if (raw.length > 65536) throw new IllegalArgumentException("Corpus too large");
        List<?> records = JSON.readValue(raw, List.class);
        if (records.size() > 50) throw new IllegalArgumentException("Maximum 50 public records");
        long now = Instant.now().getEpochSecond();
        var ids = new HashSet<String>();
        for (Object x : records) {
          var m = (Map<String, Object>) x;
          if (!m.keySet()
              .equals(Set.of("id", "title", "body", "source", "updated_at", "expires_at")))
            throw new IllegalArgumentException("Unexpected record fields");
          for (String key : List.of("id", "title", "body", "source"))
            if (!(m.get(key) instanceof String s)
                || s.isBlank()
                || s.getBytes(java.nio.charset.StandardCharsets.UTF_8).length
                    > switch (key) {
                      case "body" -> 600;
                      case "id" -> 80;
                      default -> 120;
                    }) throw new IllegalArgumentException("Invalid " + key);
          if (canonical(m).length > 1000)
            throw new IllegalArgumentException("Encoded record exceeds 1000 bytes");
          if (!ids.add((String) m.get("id"))
              || number(m, "updated_at") < 0
              || number(m, "updated_at") > now
              || number(m, "expires_at") <= now
              || number(m, "expires_at") <= number(m, "updated_at"))
            throw new IllegalArgumentException("Invalid record dates/ID");
        }
        db.setAutoCommit(false);
        try {
          try (var s = db.createStatement()) {
            s.executeUpdate("DELETE FROM campus_records");
          }
          try (var s =
              db.prepareStatement(
                  "INSERT INTO campus_records(id,title,body,source,updated_at,expires_at)"
                      + " VALUES(?,?,?,?,?,?)")) {
            for (Object x : records) {
              var m = (Map<?, ?>) x;
              int i = 1;
              for (String k : List.of("id", "title", "body", "source", "updated_at", "expires_at"))
                s.setObject(i++, m.get(k));
              s.addBatch();
            }
            s.executeBatch();
          }
          db.commit();
        } catch (Exception e) {
          db.rollback();
          throw e;
        }
      } else throw new IllegalArgumentException("Unknown command");
    }
  }
}
