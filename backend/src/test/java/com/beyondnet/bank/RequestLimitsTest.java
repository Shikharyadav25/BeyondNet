package com.beyondnet.bank;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.*;

class RequestLimitsTest {
  @Test void normalizesCapabilityRoutesAndBoundsMemory() {
    RequestLimits limits = new RequestLimits();
    assertEquals(RequestLimits.route("/api/mailbox/a"), RequestLimits.route("/api/mailbox/b"));
    long now = 100_000_000_000L;
    for (int i = 0; i < 10000; i++) assertTrue(limits.allow("client" + i, 240, now));
    assertFalse(limits.allow("extra", 240, now));
    assertTrue(limits.allow("extra", 240, now + 61_000_000_000L));
  }
  @Test void forwardedAddressIsTrustedOnlyFromLoopbackAndUsesLastHop() {
    var r = new MockHttpServletRequest();
    r.setRemoteAddr("127.0.0.1");
    r.addHeader("X-Forwarded-For", "1.1.1.1, 203.0.113.7");
    assertEquals("203.0.113.7", RequestLimits.clientIp(r));
    r.setRemoteAddr("198.51.100.8");
    assertEquals("198.51.100.8", RequestLimits.clientIp(r));
  }
  @Test void publicTunnelCannotOpenDashboardButCanReachHealth() throws Exception {
    var limits = new RequestLimits();
    var r = new MockHttpServletRequest("GET", "/api/admin/state");
    r.setRemoteAddr("127.0.0.1");
    r.addHeader("X-Forwarded-For", "203.0.113.7");
    var response = new MockHttpServletResponse();
    limits.doFilter(r, response, new MockFilterChain());
    assertEquals(403, response.getStatus());
    r = new MockHttpServletRequest("GET", "/api/health");
    r.setRemoteAddr("127.0.0.1");
    r.addHeader("X-Forwarded-For", "203.0.113.7");
    response = new MockHttpServletResponse();
    var chain = new MockFilterChain();
    limits.doFilter(r, response, chain);
    assertNotNull(chain.getRequest());
  }
  @Test void accountAttemptsAreSharedAcrossClientAddresses() throws Exception {
    var limits = new RequestLimits();
    for (int i = 0; i < 13; i++) {
      var r = new MockHttpServletRequest("POST", "/api/login");
      r.setRemoteAddr("127.0.0.1");
      r.addHeader("X-Forwarded-For", "203.0.113." + i);
      r.setContent("{\"account\":\"PAYER@beyondnet\",\"password\":\"x\"}".getBytes());
      var response = new MockHttpServletResponse();
      limits.doFilter(r, response, new MockFilterChain());
      assertEquals(i == 12 ? 429 : 200, response.getStatus());
    }
  }
}
