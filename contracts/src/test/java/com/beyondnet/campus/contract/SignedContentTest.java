package com.beyondnet.campus.contract;

import static com.beyondnet.campus.contract.SignedContent.*;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.*;
import java.security.*;
import java.util.*;
import org.junit.jupiter.api.Test;

class SignedContentTest {
  @Test
  void signaturesBindContentAndDomain() throws Exception {
    var keys = KeyPairGenerator.getInstance("Ed25519").generateKeyPair();
    var body =
        new HashMap<String, Object>(
            Map.of(
                "v",
                1,
                "kind",
                "search_result",
                "query",
                "library",
                "created_at",
                100,
                "expires_at",
                160));
    var envelope = sign(body, keys.getPrivate());
    assertEquals(body, verify(envelope, keys.getPublic()));
    body.put("query", "altered");
    assertThrows(IllegalArgumentException.class, () -> verify(envelope, keys.getPublic()));
    assertThrows(IllegalArgumentException.class, () -> canonical(Map.of("float", 1.5)));
  }

  @Test
  void utf8AndFreshnessLimits() {
    assertEquals("library", query(" library "));
    assertThrows(IllegalArgumentException.class, () -> query("é".repeat(129)));
    assertThrows(
        IllegalArgumentException.class,
        () -> fresh(Map.of("created_at", 100, "expires_at", 160), 160));
    assertThrows(
        IllegalArgumentException.class,
        () -> fresh(Map.of("created_at", 200, "expires_at", 260), 100));
  }

  @Test
  void independentGoldenVector() throws Exception {
    var f = JSON.readValue(Files.readAllBytes(Path.of("vectors/campus-v1.json")), Map.class);
    assertEquals(
        f.get("canonical"),
        new String(canonical(f.get("body")), java.nio.charset.StandardCharsets.UTF_8));
    assertEquals(
        f.get("body"),
        verify((Map<String, Object>) f.get("signed"), publicKey((String) f.get("public_key"))));
  }
}
