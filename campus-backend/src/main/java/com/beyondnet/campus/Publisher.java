package com.beyondnet.campus;

import com.beyondnet.campus.contract.SignedContent;
import java.nio.file.*;
import java.security.*;
import java.security.spec.*;
import java.util.*;
import org.springframework.stereotype.Component;

@Component
public class Publisher {
  private final PrivateKey key;
  public final String publicKey;

  @org.springframework.beans.factory.annotation.Autowired
  public Publisher() throws Exception {
    // Explicit provisioning: never silently replace a trusted publisher identity.
    Path directory = Path.of(System.getenv().getOrDefault("CAMPUS_KEYS_DIR", "data/campus-keys"));
    key =
        KeyFactory.getInstance("Ed25519")
            .generatePrivate(
                new PKCS8EncodedKeySpec(Files.readAllBytes(directory.resolve("publisher.pk8"))));
    byte[] pub = Files.readAllBytes(directory.resolve("publisher.der"));
    publicKey = Base64.getEncoder().encodeToString(pub);
    SignedContent.verify(
        SignedContent.sign(Map.of("check", true), key), SignedContent.publicKey(publicKey));
  }

  Publisher(KeyPair pair) {
    key = pair.getPrivate();
    publicKey = Base64.getEncoder().encodeToString(pair.getPublic().getEncoded());
  }

  public Map<String, Object> sign(Map<String, Object> body) {
    return SignedContent.sign(body, key);
  }
}
