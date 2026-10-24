package com.beyondnet.campus;

import static com.beyondnet.campus.contract.SignedContent.*;

import jakarta.servlet.*;
import jakarta.servlet.http.*;
import java.io.*;
import java.time.Instant;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class CampusAccess extends OncePerRequestFilter {
  private final JdbcTemplate db;
  private final Map<String, long[]> windows = new HashMap<>();

  public CampusAccess(JdbcTemplate db) {
    this.db = db;
  }

  synchronized boolean allow(String id, long now) {
    windows.entrySet().removeIf(e -> e.getValue()[0] < now - 60);
    if (!windows.containsKey(id) && windows.size() >= 10000) return false;
    long[] bucket = windows.computeIfAbsent(id, k -> new long[] {now, 0});
    return ++bucket[1] <= 120;
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain chain)
      throws ServletException, IOException {
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    long now = Instant.now().getEpochSecond();
    if (!allow("ip:" + request.getRemoteAddr(), now)) {
      response.sendError(429);
      return;
    }
    if (!request.getRequestURI().equals("/campus/v1/capabilities")) {
      String auth = request.getHeader("Authorization");
      if (auth == null || !auth.startsWith("Bearer ") || auth.length() > 512) {
        response.sendError(401);
        return;
      }
      var rows =
          db.queryForList(
              "SELECT id FROM campus_principals WHERE token_hash=? AND expires_at>? AND"
                  + " revoked=FALSE",
              hash(auth.substring(7)),
              now);
      if (rows.isEmpty()) {
        response.sendError(401);
        return;
      }
      if (!allow("user:" + rows.getFirst().get("id"), now)) {
        response.sendError(429);
        return;
      }
      request.setAttribute("campus_principal", rows.getFirst().get("id"));
    }
    byte[] body = request.getInputStream().readNBytes(16385);
    if (body.length > 16384) {
      response.sendError(413);
      return;
    }
    chain.doFilter(
        new HttpServletRequestWrapper(request) {
          @Override
          public ServletInputStream getInputStream() {
            var input = new ByteArrayInputStream(body);
            return new ServletInputStream() {
              public int read() {
                return input.read();
              }

              public boolean isFinished() {
                return input.available() == 0;
              }

              public boolean isReady() {
                return true;
              }

              public void setReadListener(ReadListener l) {
                throw new UnsupportedOperationException();
              }
            };
          }

          @Override
          public BufferedReader getReader() {
            return new BufferedReader(
                new InputStreamReader(getInputStream(), java.nio.charset.StandardCharsets.UTF_8));
          }
        },
        response);
  }
}
