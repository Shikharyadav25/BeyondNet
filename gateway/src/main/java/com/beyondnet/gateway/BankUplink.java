package com.beyondnet.gateway;

import static com.beyondnet.campus.contract.SignedContent.*;

import java.net.*;
import java.net.http.*;
import java.time.Duration;
import java.util.Map;

/** Fixed bank destination. Tokens have only gateway submit/mailbox permissions. */
public final class BankUplink {
  private final URI bank;
  private final String token;
  private final HttpClient client =
      HttpClient.newBuilder()
          .connectTimeout(Duration.ofSeconds(10))
          .followRedirects(HttpClient.Redirect.NEVER)
          .build();

  public BankUplink(String endpoint, String token) {
    bank = URI.create(endpoint);
    if (!"https".equals(bank.getScheme())
        || bank.getHost() == null
        || bank.getUserInfo() != null
        || bank.getQuery() != null
        || bank.getFragment() != null
        || !(bank.getPath().isEmpty() || bank.getPath().equals("/")))
      throw new IllegalArgumentException("Expected an HTTPS bank origin");
    if (token == null || token.isBlank())
      throw new IllegalArgumentException("Provision gateway credentials first");
    this.token = token;
  }

  public byte[] submitOrRecover(DurableQueue.Item item, long now) throws Exception {
    var builder =
        HttpRequest.newBuilder()
            .timeout(Duration.ofSeconds(15))
            .header("Authorization", "Bearer " + token);
    if (item.expires() > now) {
      builder
          .uri(bank.resolve("/api/gateway/packets"))
          .header("Content-Type", "application/json")
          .POST(HttpRequest.BodyPublishers.ofByteArray(item.payload()));
    } else {
      Map<?, ?> packet = JSON.readValue(item.payload(), Map.class);
      Object cap = packet.get("mailbox");
      if (!(cap instanceof String s) || !s.matches("[a-fA-F0-9]{32,100}"))
        throw new IllegalArgumentException("Invalid mailbox capability");
      builder.uri(bank.resolve("/api/gateway/mailbox/" + s)).GET();
    }
    var response = client.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream());
    try (var input = response.body()) {
      byte[] bytes = input.readNBytes(12289);
      if (response.statusCode() != 200 || bytes.length > 12288)
        throw new IllegalStateException("Bank result unavailable; preserve original request");
      Map<?, ?> body = JSON.readValue(bytes, Map.class);
      if (!(body.get("receipts") instanceof java.util.List<?> receipts) || receipts.isEmpty())
        throw new IllegalStateException("No authoritative receipt yet");
      // Transport result only: the originating phone verifies the original bank signatures.
      return bytes;
    }
  }
}
