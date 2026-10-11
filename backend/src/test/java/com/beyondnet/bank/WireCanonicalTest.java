package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class WireCanonicalTest {
  @Test void controlCharacterEscapesMatchDart() {
    assertEquals("{\"name\":\"\\u001b\\u000f\\n\"}",
        new String(canonical(map("name", "\u001b\u000f\n")), java.nio.charset.StandardCharsets.UTF_8));
  }
  @Test void nonAsciiTextKeepsItsExistingUtf8CanonicalBytes() {
    assertEquals("{\"name\":\"café ₹ ☕ 😀\"}",
        new String(canonical(map("name", "café ₹ ☕ 😀")), java.nio.charset.StandardCharsets.UTF_8));
  }
}
