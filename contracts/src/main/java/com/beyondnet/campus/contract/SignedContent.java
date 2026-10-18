package com.beyondnet.campus.contract;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.*;
import java.util.*;

/** Campus-only domain. Never pass these objects to the payment protocol. */
public final class SignedContent {
  public static final ObjectMapper JSON = new ObjectMapper();
  public static final String DOMAIN = "beyondnet/campus/v1\n";
  public static final int MAX_QUERY = 256, MAX_RESPONSE = 4096, MAX_MESSAGE = 1024;
  public static final String SERVICE_UUID = "5cebe240-7de4-43eb-843b-96260d973a10";
  public static final String CHARACTERISTIC_UUID = "5cebe240-7de4-43eb-843b-96260d973a11";

  private SignedContent() {}

  public static byte[] canonical(Object value) {
    try {
      return JSON.writeValueAsBytes(sorted(value));
    } catch (Exception e) {
      throw new IllegalArgumentException("Invalid campus content", e);
    }
  }

  private static Object sorted(Object x) {
    if (x instanceof Map<?, ?> m) {
      var result = new TreeMap<String, Object>();
      for (var e : m.entrySet()) {
        if (!(e.getKey() instanceof String k))
          throw new IllegalArgumentException("String keys required");
        result.put(k, sorted(e.getValue()));
      }
      return result;
    }
    if (x instanceof List<?> l) return l.stream().map(SignedContent::sorted).toList();
    if (x == null
        || x instanceof String
        || x instanceof Boolean
        || x instanceof Integer
        || x instanceof Long) return x;
    throw new IllegalArgumentException(
        "Only integers, strings, booleans, null, arrays and objects permitted");
  }

  public static String hash(Object x) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(canonical(x)));
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException(e);
    }
  }

  public static Map<String, Object> sign(Map<String, Object> body, PrivateKey key) {
    try {
      var signature = Signature.getInstance("Ed25519");
      signature.initSign(key);
      signature.update(DOMAIN.getBytes(StandardCharsets.UTF_8));
      signature.update(canonical(body));
      return Map.of(
          "body", body, "signature", Base64.getEncoder().encodeToString(signature.sign()));
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException(e);
    }
  }

  @SuppressWarnings("unchecked")
  public static Map<String, Object> verify(Map<String, Object> envelope, PublicKey key) {
    try {
      if (!envelope.keySet().equals(Set.of("body", "signature")))
        throw new IllegalArgumentException();
      var body = (Map<String, Object>) envelope.get("body");
      var signature = Signature.getInstance("Ed25519");
      signature.initVerify(key);
      signature.update(DOMAIN.getBytes(StandardCharsets.UTF_8));
      signature.update(canonical(body));
      if (!signature.verify(Base64.getDecoder().decode((String) envelope.get("signature"))))
        throw new IllegalArgumentException();
      return body;
    } catch (Exception e) {
      throw new IllegalArgumentException("Untrusted campus signature", e);
    }
  }

  public static PublicKey publicKey(String encoded) {
    try {
      return KeyFactory.getInstance("Ed25519")
          .generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(encoded)));
    } catch (Exception e) {
      throw new IllegalArgumentException("Invalid publisher key", e);
    }
  }

  public static long number(Map<String, Object> body, String field) {
    Object n = body.get(field);
    if (!(n instanceof Integer || n instanceof Long))
      throw new IllegalArgumentException("Invalid " + field);
    return ((Number) n).longValue();
  }

  public static void fresh(Map<String, Object> body, long now) {
    long created = number(body, "created_at"), expires = number(body, "expires_at");
    if (created > now + 30 || expires <= now || expires <= created)
      throw new IllegalArgumentException("Campus content expired or clock incorrect");
  }

  public static String query(String query) {
    if (query == null
        || query.isBlank()
        || query.getBytes(StandardCharsets.UTF_8).length > MAX_QUERY)
      throw new IllegalArgumentException("Enter a query of 1–256 UTF-8 bytes");
    return query.strip();
  }
}
