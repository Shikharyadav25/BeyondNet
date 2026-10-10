package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import jakarta.annotation.PreDestroy;
import java.nio.channels.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.sql.*;
import java.util.*;
import org.springframework.stereotype.Component;

@Component
public class BankDatabase implements AutoCloseable {
  public final Path directory;
  public final String operatorKey;
  private final FileChannel lockChannel;
  private final FileLock lease;
  private final String url, user, password, schema;

  public BankDatabase() {
    this(
        Path.of(System.getenv().getOrDefault("KARO_DATA_DIR", "data")).toAbsolutePath(),
        System.getenv().getOrDefault("BEYONDNET_DB_SCHEMA", "public"));
  }

  public BankDatabase(Path dir) {
    this(dir, "test_" + UUID.randomUUID().toString().replace("-", ""));
  }

  public BankDatabase(Path dir, String namespace) {
    directory = dir.toAbsolutePath();
    schema = namespace;
    if (!schema.matches("[a-z][a-z0-9_]{0,62}"))
      throw new IllegalArgumentException("Invalid database schema");
    Properties config = new Properties();
    try {
      Path cfg =
          Path.of(System.getenv().getOrDefault("BEYONDNET_DB_CONFIG", "data/postgres.properties"))
              .toAbsolutePath();
      if (Files.exists(cfg))
        try (var input = Files.newInputStream(cfg)) {
          config.load(input);
        }
      url =
          System.getenv()
              .getOrDefault(
                  "BEYONDNET_DB_URL",
                  config.getProperty("url", "jdbc:postgresql://127.0.0.1:5433/beyondnet"));
      user =
          System.getenv()
              .getOrDefault("BEYONDNET_DB_USER", config.getProperty("user", "beyondnet"));
      password =
          System.getenv().getOrDefault("BEYONDNET_DB_PASSWORD", config.getProperty("password", ""));
      if (!url.startsWith("jdbc:postgresql:"))
        throw new IllegalArgumentException("The live bank requires PostgreSQL");
      Files.createDirectories(directory);
      protect(directory, "rwx------");
      lockChannel =
          FileChannel.open(
              directory.resolve(".bank-java.lock"),
              StandardOpenOption.CREATE,
              StandardOpenOption.WRITE);
      lease = lockChannel.tryLock();
      if (lease == null)
        throw new IllegalStateException("Another Java bank owns this data directory");
      // Schema is validated above. Test schemas keep every test isolated from real records.
      try (Connection c = rawConnect()) {
        execute(c, "CREATE SCHEMA IF NOT EXISTS " + schema);
      }
      tx(
          c -> {
            try (var input = getClass().getResourceAsStream("/schema.sql")) {
              String ddl =
                  new String(input.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
              for (String sql : ddl.split(";")) if (!sql.isBlank()) execute(c, sql);
            }
            if (Files.exists(directory.resolve("bank.sqlite3")))
              LegacySqliteImport.importInto(c, directory.resolve("bank.sqlite3"));
            // An existing ledger keeps its exact account set; seed only a genuinely empty bank.
            if (scalar(c, "SELECT COUNT(*) FROM accounts") == 0) {
              try (var input = getClass().getResourceAsStream("/demo-accounts.json")) {
                List<?> seeds = JSON.readValue(input, List.class);
                for (Object entry : seeds) {
                  List<?> a = (List<?>) entry;
                  byte[] salt = random(16);
                  update(
                      c,
                      "INSERT INTO accounts VALUES(?,?,?,?,?,?)",
                      a.get(0),
                      a.get(1),
                      a.get(2),
                      a.get(3),
                      salt,
                      passwordHash((String) a.get(4), salt));
                }
              }
            }
            update(c, "UPDATE accounts SET role='customer' WHERE role='relay'");
            return null;
          });
      Path file = directory.resolve("admin-token.txt");
      if (!Files.exists(file)) Files.writeString(file, token(), StandardOpenOption.CREATE_NEW);
      protect(file, "rw-------");
      operatorKey = Files.readString(file).trim();
    } catch (Exception e) {
      throw new IllegalStateException(
          "Cannot open PostgreSQL bank safely. Check database configuration; original data has not"
              + " been deleted.",
          e);
    }
  }

  public static void protect(Path file, String permissions) throws Exception {
    if (Files.getFileStore(file).supportsFileAttributeView("posix"))
      Files.setPosixFilePermissions(file, PosixFilePermissions.fromString(permissions));
  }

  private Connection rawConnect() throws SQLException {
    Properties props = new Properties();
    props.setProperty("user", user);
    props.setProperty("password", password);
    props.setProperty("connectTimeout", "5");
    props.setProperty("socketTimeout", "65");
    return DriverManager.getConnection(url, props);
  }

  public Connection connect() throws SQLException {
    Connection c = rawConnect();
    try {
      execute(c, "SET search_path TO " + schema);
      execute(c, "SET statement_timeout='60s'");
      execute(c, "SET lock_timeout='30s'");
      return c;
    } catch (SQLException e) {
      c.close();
      throw e;
    }
  }

  @FunctionalInterface
  public interface Work<T> {
    T run(Connection c) throws Exception;
  }

  public <T> T read(Work<T> work) {
    try (Connection c = connect()) {
      return work.run(c);
    } catch (BankException e) {
      throw e;
    } catch (Exception e) {
      throw new IllegalStateException("Bank database operation failed", e);
    }
  }

  public <T> T tx(Work<T> work) {
    return read(
        c -> {
          c.setAutoCommit(false);
          try {
            // Database-wide per-bank lock protects read/check/write sequences across Java
            // processes.
            // READ COMMITTED gives a fresh snapshot after the previous lock holder commits.
            execute(c, "SELECT pg_advisory_xact_lock(724190,hashtext(current_schema()))");
            T result = work.run(c);
            c.commit();
            return result;
          } catch (Exception e) {
            try {
              c.rollback();
            } catch (SQLException rollback) {
              e.addSuppressed(rollback);
            }
            throw e;
          }
        });
  }

  public String namespace() {
    return schema;
  }

  public void dropTestSchema() {
    if (!schema.startsWith("test_"))
      throw new IllegalStateException("Only test schemas can be dropped");
    read(
        c -> {
          execute(c, "DROP SCHEMA " + schema + " CASCADE");
          return null;
        });
  }

  public static void execute(Connection c, String sql) throws SQLException {
    try (Statement s = c.createStatement()) {
      s.execute(sql);
    }
  }

  public static PreparedStatement statement(Connection c, String sql, Object... args)
      throws SQLException {
    PreparedStatement s = c.prepareStatement(sql);
    for (int i = 0; i < args.length; i++) s.setObject(i + 1, args[i]);
    return s;
  }

  public static int update(Connection c, String sql, Object... args) throws SQLException {
    try (PreparedStatement s = statement(c, sql, args)) {
      return s.executeUpdate();
    }
  }

  public static List<Map<String, Object>> rows(Connection c, String sql, Object... args)
      throws SQLException {
    try (PreparedStatement s = statement(c, sql, args);
        ResultSet r = s.executeQuery()) {
      List<Map<String, Object>> out = new ArrayList<>();
      ResultSetMetaData meta = r.getMetaData();
      while (r.next()) {
        Map<String, Object> row = new LinkedHashMap<>();
        for (int i = 1; i <= meta.getColumnCount(); i++)
          row.put(meta.getColumnLabel(i), r.getObject(i));
        out.add(row);
      }
      return out;
    }
  }

  public static Map<String, Object> one(Connection c, String sql, Object... args)
      throws SQLException {
    List<Map<String, Object>> result = rows(c, sql, args);
    return result.isEmpty() ? null : result.getFirst();
  }

  public static long scalar(Connection c, String sql, Object... args) throws SQLException {
    return ((Number) one(c, sql, args).values().iterator().next()).longValue();
  }

  public static void event(Connection c, String kind, Object detail) throws SQLException {
    update(c, "INSERT INTO events(at,kind,detail) VALUES(?,?,?)", now(), kind, json(detail));
  }

  @PreDestroy
  public void close() {
    try {
      if (lease != null && lease.isValid()) lease.release();
      lockChannel.close();
    } catch (Exception ignored) {
    }
  }
}
