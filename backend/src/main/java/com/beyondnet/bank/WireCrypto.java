package com.beyondnet.bank;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.*;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.bouncycastle.crypto.agreement.X25519Agreement;
import org.bouncycastle.crypto.digests.SHA256Digest;
import org.bouncycastle.crypto.generators.HKDFBytesGenerator;
import org.bouncycastle.crypto.generators.SCrypt;
import org.bouncycastle.crypto.params.*;
import org.bouncycastle.crypto.signers.Ed25519Signer;

/** Byte-compatible v1 envelope; v2 authorization stays inside the encrypted body. */
public final class WireCrypto {
  public static final ObjectMapper JSON =
      new ObjectMapper(
              com.fasterxml.jackson.core.JsonFactory.builder()
                  .streamReadConstraints(
                      com.fasterxml.jackson.core.StreamReadConstraints.builder()
                          .maxNestingDepth(64)
                          .build())
                  .build())
          .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION);
  private static final SecureRandom RANDOM = new SecureRandom();
  private static final byte[] DOMAIN = "offline-karo/box/v1".getBytes(StandardCharsets.UTF_8);

  private WireCrypto() {}

  public static Map<String, Object> map(Object... fields) {
    Map<String, Object> m = new LinkedHashMap<>();
    for (int i = 0; i < fields.length; i += 2) m.put((String) fields[i], fields[i + 1]);
    return m;
  }

  public static Map<String, Object> parse(String text) {
    try {
      return JSON.readValue(text, new TypeReference<>() {});
    } catch (Exception e) {
      throw new BankException(400, "Invalid JSON");
    }
  }

  public static String json(Object value) {
    try {
      return JSON.writeValueAsString(value);
    } catch (Exception e) {
      throw new IllegalArgumentException("Invalid JSON value", e);
    }
  }

  private static Object sorted(Object v) {
    if (v instanceof Map<?, ?> input) {
      Map<String, Object> out = new TreeMap<>();
      input.forEach((k, x) -> out.put((String) k, sorted(x)));
      return out;
    }
    if (v instanceof List<?> input) return input.stream().map(WireCrypto::sorted).toList();
    if (v instanceof Float || v instanceof Double)
      throw new IllegalArgumentException("Floats are not wire values");
    return v;
  }

  public static byte[] canonical(Object v) {
    return json(sorted(v)).getBytes(StandardCharsets.UTF_8);
  }

  public static String digest(Object v) {
    return hash(canonical(v));
  }

  public static String hash(byte[] value) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value));
    } catch (Exception e) {
      throw new IllegalStateException(e);
    }
  }

  public static byte[] random(int n) {
    byte[] out = new byte[n];
    RANDOM.nextBytes(out);
    return out;
  }

  public static String token() {
    return Base64.getUrlEncoder().withoutPadding().encodeToString(random(32));
  }

  public static String b64(byte[] x) {
    return Base64.getEncoder().encodeToString(x);
  }

  public static byte[] unb64(String s) {
    return Base64.getDecoder().decode(s);
  }

  public static String signPublic(byte[] seed) {
    return b64(new Ed25519PrivateKeyParameters(seed, 0).generatePublicKey().getEncoded());
  }

  public static String boxPublic(byte[] seed) {
    return b64(new X25519PrivateKeyParameters(seed, 0).generatePublicKey().getEncoded());
  }

  public static Map<String, Object> sign(byte[] seed, Map<String, Object> body) {
    Ed25519Signer signer = new Ed25519Signer();
    signer.init(true, new Ed25519PrivateKeyParameters(seed, 0));
    byte[] bytes = canonical(body);
    signer.update(bytes, 0, bytes.length);
    return map("body", body, "signature", b64(signer.generateSignature()));
  }

  @SuppressWarnings("unchecked")
  public static Map<String, Object> verify(String publicKey, Map<String, Object> signed) {
    byte[] key = unb64(publicKey);
    if (key.length != 32) throw new IllegalArgumentException("Invalid key length");
    Map<String, Object> body = (Map<String, Object>) signed.get("body");
    Ed25519Signer signer = new Ed25519Signer();
    signer.init(false, new Ed25519PublicKeyParameters(key, 0));
    byte[] bytes = canonical(body);
    signer.update(bytes, 0, bytes.length);
    if (!signer.verifySignature(unb64((String) signed.get("signature"))))
      throw new IllegalArgumentException("Invalid signature");
    return body;
  }

  private static byte[] secret(byte[] seed, byte[] peer, byte[] ep, byte[] recipient) {
    if (seed.length != 32 || peer.length != 32 || ep.length != 32 || recipient.length != 32)
      throw new IllegalArgumentException("Invalid key length");
    X25519Agreement exchange = new X25519Agreement();
    exchange.init(new X25519PrivateKeyParameters(seed, 0));
    byte[] shared = new byte[32];
    exchange.calculateAgreement(new X25519PublicKeyParameters(peer, 0), shared, 0);
    byte[] salt = new byte[64];
    System.arraycopy(ep, 0, salt, 0, 32);
    System.arraycopy(recipient, 0, salt, 32, 32);
    HKDFBytesGenerator hkdf = new HKDFBytesGenerator(new SHA256Digest());
    hkdf.init(new HKDFParameters(shared, salt, DOMAIN));
    byte[] out = new byte[32];
    hkdf.generateBytes(out, 0, 32);
    Arrays.fill(shared, (byte) 0);
    return out;
  }

  private static byte[] aes(int mode, byte[] key, byte[] nonce, byte[] data) {
    if (nonce.length != 12) throw new IllegalArgumentException("Invalid nonce");
    try {
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
      cipher.updateAAD(DOMAIN);
      return cipher.doFinal(data);
    } catch (Exception e) {
      throw new IllegalArgumentException("Encrypted envelope verification failed");
    } finally {
      Arrays.fill(key, (byte) 0);
    }
  }

  public static Map<String, Object> seal(String recipientKey, Object value) {
    byte[] seed = random(32),
        ep = unb64(boxPublic(seed)),
        recipient = unb64(recipientKey),
        nonce = random(12);
    byte[] ct =
        aes(Cipher.ENCRYPT_MODE, secret(seed, recipient, ep, recipient), nonce, canonical(value));
    Arrays.fill(seed, (byte) 0);
    return map("ephemeral", b64(ep), "nonce", b64(nonce), "ciphertext", b64(ct));
  }

  public static Map<String, Object> openBox(byte[] seed, Map<String, Object> box) {
    byte[] ep = unb64((String) box.get("ephemeral")), recipient = unb64(boxPublic(seed));
    return parse(
        new String(
            aes(
                Cipher.DECRYPT_MODE,
                secret(seed, ep, ep, recipient),
                unb64((String) box.get("nonce")),
                unb64((String) box.get("ciphertext"))),
            StandardCharsets.UTF_8));
  }

  public static String passwordHash(String password, byte[] salt) {
    return HexFormat.of()
        .formatHex(
            SCrypt.generate(password.getBytes(StandardCharsets.UTF_8), salt, 16384, 8, 1, 64));
  }

  public static boolean equal(String a, String b) {
    return MessageDigest.isEqual(
        a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8));
  }

  public static long now() {
    return System.currentTimeMillis() / 1000;
  }

  public static long integer(Object x) {
    if (!(x instanceof Integer || x instanceof Long))
      throw new IllegalArgumentException("Integer required");
    return ((Number) x).longValue();
  }

  public static Map<String, Object> packet(
      String kind, Map<String, Object> box, String mailbox, long expiry, List<?> path) {
    Map<String, Object> core =
        map("v", 1, "kind", kind, "mailbox", mailbox, "box", box, "expires_at", expiry);
    String id = digest(core);
    core.putAll(map("id", id, "hops", 0, "path", path));
    return core;
  }

  public static void checkPacket(Map<String, Object> p) {
    if (canonical(p).length > 8192
        || integer(p.get("v")) != 1
        || !List.of("payment", "receipt").contains(p.get("kind")))
      throw new IllegalArgumentException("Invalid packet");
    if (!digest(
            map(
                "v",
                p.get("v"),
                "kind",
                p.get("kind"),
                "mailbox",
                p.get("mailbox"),
                "box",
                p.get("box"),
                "expires_at",
                p.get("expires_at")))
        .equals(p.get("id"))) throw new IllegalArgumentException("Packet integrity mismatch");
    long hops = integer(p.get("hops"));
    if (hops < 0 || hops > 4) throw new IllegalArgumentException("Hop budget exceeded");
    if (!(p.get("path") instanceof List<?> path)
        || path.size() > 8
        || path.stream().anyMatch(x -> !(x instanceof String s) || s.length() > 80))
      throw new IllegalArgumentException("Invalid path");
    if (!(p.get("mailbox") instanceof String s) || s.length() < 32 || s.length() > 100)
      throw new IllegalArgumentException("Invalid mailbox");
    integer(p.get("expires_at"));
  }
}
