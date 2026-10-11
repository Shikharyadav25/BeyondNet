package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import jakarta.annotation.PreDestroy;
import java.nio.channels.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.sql.*;
import java.util.*;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.stereotype.Component;

@Component
public class BankDatabase implements AutoCloseable {
  public final Path directory;
  public final String operatorKey;
  private final FileChannel lockChannel;
  private final FileLock lease;
  private final String url, user, password, schema;
  private final HikariDataSource pool;
  final List<Runnable> commitListeners = new java.util.concurrent.CopyOnWriteArrayList<>();

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
      HikariConfig pooling = new HikariConfig();
      pooling.setJdbcUrl(url);
      pooling.setUsername(user);
      pooling.setPassword(password);
      pooling.setMaximumPoolSize(4);
      pooling.setMinimumIdle(0);
      pooling.setConnectionTimeout(10000);
      pooling.setConnectionInitSql("SET search_path TO " + schema
          + "; SET statement_timeout='60s'; SET lock_timeout='30s'");
      pooling.addDataSourceProperty("connectTimeout", "5");
      pooling.addDataSourceProperty("socketTimeout", "65");
      pool = new HikariDataSource(pooling);
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
            // Fresh banks start empty: users sign up with their own credentials.
            update(c, "UPDATE accounts SET role='customer' WHERE role='relay'");
            return null;
          });
      Path file = directory.resolve("admin-token.txt");
      if (!Files.exists(file)) privateFile(file, token());
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
    return pool.getConnection();
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
    T result = read(
        c -> {
          c.setAutoCommit(false);
          try {
            // Database-wide per-bank lock protects read/check/write sequences across Java
            // processes.
            // READ COMMITTED gives a fresh snapshot after the previous lock holder commits.
            execute(c, "SELECT pg_advisory_xact_lock(724190,hashtext(current_schema()))");
            T outcome = work.run(c);
            c.commit();
            return outcome;
          } catch (Exception e) {
            try {
              c.rollback();
            } catch (SQLException rollback) {
              e.addSuppressed(rollback);
            }
            throw e;
          }
        });
    // Notify only after commit and after returning the connection to the pool.
    for (Runnable listener : commitListeners) {
      try { listener.run(); } catch (RuntimeException ignored) { }
    }
    return result;
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
    pool.close();
    try {
      if (lease != null && lease.isValid()) lease.release();
      lockChannel.close();
    } catch (Exception ignored) {
    }
  }

  /** Restrict access from the first filesystem operation, before writing secrets. */
  public static void privateFile(Path file, String content) throws Exception {
    try {
      Files.createFile(file, PosixFilePermissions.asFileAttribute(
          PosixFilePermissions.fromString("rw-------")));
    } catch (UnsupportedOperationException e) {
      Files.createFile(file);
      protect(file, "rw-------");
    }
    Files.writeString(file, content, StandardOpenOption.WRITE);
  }
}
