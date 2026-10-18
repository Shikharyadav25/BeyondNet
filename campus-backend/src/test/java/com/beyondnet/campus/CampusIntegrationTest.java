package com.beyondnet.campus;

import static com.beyondnet.campus.contract.SignedContent.*;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import java.security.*;
import java.sql.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.*;

@EnabledIfEnvironmentVariable(named = "CAMPUS_TEST_DB_URL", matches = ".+")
class CampusIntegrationTest {
  JdbcTemplate db;
  String schema;
  CampusController controller;
  Publisher publisher;
  CampusAccess access;

  @BeforeEach
  void setup() throws Exception {
    schema = "test_" + UUID.randomUUID().toString().replace("-", "");
    String url = System.getenv("CAMPUS_TEST_DB_URL"),
        user = System.getenv().getOrDefault("CAMPUS_TEST_DB_USER", "beyondnet_test");
    var ds = new DriverManagerDataSource(url, user, System.getenv().getOrDefault("CAMPUS_TEST_DB_PASSWORD", ""));
    db = new JdbcTemplate(ds);
    db.execute("CREATE SCHEMA " + schema);
    ds.setUrl(url + (url.contains("?") ? "&" : "?") + "currentSchema=" + schema);
    String ddl =
        new String(
            getClass().getResourceAsStream("/schema.sql").readAllBytes(), StandardCharsets.UTF_8);
    for (String sql : ddl.split(";")) if (!sql.isBlank()) db.execute(sql);
    publisher = new Publisher(KeyPairGenerator.getInstance("Ed25519").generateKeyPair());
    controller = new CampusController(db, publisher);
    access = new CampusAccess(db);
  }

  @AfterEach
  void close() {
    if (db != null && schema != null) db.execute("DROP SCHEMA " + schema + " CASCADE");
  }

  @Test
  void searchIsBoundedSignedDatedAndPaginated() {
    long now = Instant.now().getEpochSecond();
    for (int i = 0; i < 5; i++)
      db.update(
          "INSERT INTO campus_records(id,title,body,source,updated_at,expires_at)"
              + " VALUES(?,?,?,?,?,?)",
          "r" + i,
          "Library " + i,
          "Test record only",
          "Test publisher",
          now,
          now + 86400);
    db.update(
        "INSERT INTO campus_records(id,title,body,source,updated_at,expires_at)"
            + " VALUES('old','Library old','Expired','Test publisher',?,?)",
        now - 100,
        now - 1);
    var request =
        Map.<String, Object>of(
            "request_id", UUID.randomUUID().toString(), "query", "library", "page", 0);
    var signed = (Map<String, Object>) controller.search(request);
    assertTrue(canonical(signed).length <= 4096);
    var body = verify(signed, publicKey(publisher.publicKey));
    fresh(body, now);
    assertEquals(request.get("request_id"), body.get("request_id"));
    assertEquals(3, ((List<?>) body.get("results")).size());
    assertEquals(true, body.get("has_more"));
    var second =
        (Map<String, Object>)
            controller.search(
                Map.of("request_id", UUID.randomUUID().toString(), "query", "library", "page", 1));
    assertEquals(
        2, ((List<?>) verify(second, publicKey(publisher.publicKey)).get("results")).size());
    assertThrows(
        IllegalArgumentException.class,
        () ->
            controller.search(
                Map.of(
                    "request_id",
                    UUID.randomUUID().toString(),
                    "query",
                    "library",
                    "page",
                    0,
                    "url",
                    "http://127.0.0.1/admin")));
    var cache = verify((Map<String, Object>) controller.cache(), publicKey(publisher.publicKey));
    assertEquals(5, ((List<?>) cache.get("records")).size());
  }

  @Test
  void credentialsRevocationLimitsAndBodyBounds() throws Exception {
    long now = Instant.now().getEpochSecond();
    db.update(
        "INSERT INTO campus_principals VALUES(?,?,?,FALSE)",
        "student",
        hash("private-token"),
        now + 3600);
    assertEquals(401, request(null, new byte[0]).getStatus());
    assertEquals(200, request("private-token", new byte[0]).getStatus());
    assertEquals(413, request("private-token", new byte[16385]).getStatus());
    db.update("UPDATE campus_principals SET revoked=TRUE");
    assertEquals(401, request("private-token", new byte[0]).getStatus());
    for (int i = 0; i < 120; i++) assertTrue(access.allow("quota-student", now));
    assertFalse(access.allow("quota-student", now));
    assertTrue(access.allow("quota-student", now + 61));
  }

  MockHttpServletResponse request(String token, byte[] bytes) throws Exception {
    var req = new MockHttpServletRequest("POST", "/campus/v1/search");
    req.setRemoteAddr("127.0.0.1");
    req.setContent(bytes);
    if (token != null) req.addHeader("Authorization", "Bearer " + token);
    var res = new MockHttpServletResponse();
    access.doFilter(req, res, (a, b) -> {});
    return res;
  }
}
