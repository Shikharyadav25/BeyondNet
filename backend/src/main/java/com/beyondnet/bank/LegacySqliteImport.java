package com.beyondnet.bank;

import static com.beyondnet.bank.BankDatabase.*;
import static com.beyondnet.bank.WireCrypto.*;

import java.nio.file.*;
import java.sql.*;
import java.util.*;

/** Read-only, transactional legacy import. No live payments ever write SQLite. */
public final class LegacySqliteImport {
  private static final List<String> TABLES =
      List.of(
          "accounts",
          "sessions",
          "devices",
          "payments",
          "ledger",
          "mailboxes",
          "topups",
          "device_receipts",
          "events",
          "payment_pins");

  private LegacySqliteImport() {}

  public static void importInto(Connection target, Path source) throws Exception {
    if (one(target, "SELECT id FROM migration_meta WHERE id='sqlite-v1'") != null) return;
    for (String table : TABLES)
      if (scalar(target, "SELECT COUNT(*) FROM " + table) != 0)
        throw new IllegalStateException(
            "Refusing to merge legacy data into a populated PostgreSQL bank");
    // SQLite mode=ro prevents accidental modification; the caller must stop the old bank first.
    try (Connection old =
        DriverManager.getConnection("jdbc:sqlite:file:" + source.toAbsolutePath() + "?mode=ro")) {
      old.setAutoCommit(false);
      Map<String, Object> counts = new LinkedHashMap<>();
      for (String table : TABLES) {
        if (one(old, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", table)
            == null) {
          counts.put(table, 0);
          continue;
        }
        List<Map<String, Object>> original = rows(old, "SELECT * FROM " + table);
        for (Map<String, Object> row : original) {
          String columns = String.join(",", row.keySet()),
              marks = String.join(",", Collections.nCopies(row.size(), "?"));
          update(
              target,
              "INSERT INTO " + table + " (" + columns + ") VALUES (" + marks + ")",
              row.values().toArray());
        }
        List<Map<String, Object>> copied = rows(target, "SELECT * FROM " + table);
        if (original.size() != copied.size())
          throw new IllegalStateException("Import count mismatch: " + table);
        // Compare every value, not just totals. Numeric JDBC representations differ by driver.
        List<String> a = original.stream().map(LegacySqliteImport::normalized).sorted().toList();
        List<String> b = copied.stream().map(LegacySqliteImport::normalized).sorted().toList();
        if (!a.equals(b)) throw new IllegalStateException("Import value mismatch: " + table);
        counts.put(table, original.size());
      }
      for (String[] pair :
          List.of(
              new String[] {"ledger", "id"},
              new String[] {"events", "id"},
              new String[] {"device_receipts", "seq"})) {
        long maximum = scalar(target, "SELECT COALESCE(MAX(" + pair[1] + "),0) FROM " + pair[0]);
        try (var st =
            statement(
                target,
                "SELECT setval(pg_get_serial_sequence(?,?),?,?)",
                pair[0],
                pair[1],
                Math.max(1, maximum),
                maximum > 0)) {
          st.execute();
        }
      }
      update(target, "INSERT INTO migration_meta VALUES('sqlite-v1',?,?)", now(), json(counts));
      old.rollback();
      System.out.println(
          "Legacy SQLite records verified and imported atomically into PostgreSQL: "
              + json(counts));
    }
  }

  private static String normalized(Map<String, Object> row) {
    Map<String, Object> result = new TreeMap<>();
    row.forEach(
        (key, value) ->
            result.put(
                key,
                value instanceof byte[] bytes
                    ? b64(bytes)
                    : value instanceof Number n ? n.longValue() : value));
    return json(result);
  }
}
