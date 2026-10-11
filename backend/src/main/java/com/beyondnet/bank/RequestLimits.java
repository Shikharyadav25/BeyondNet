package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import jakarta.servlet.*;
import jakarta.servlet.http.*;
import java.io.*;
import java.util.*;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class RequestLimits extends OncePerRequestFilter {
  private final Map<String, Deque<Long>> attempts = new HashMap<>();

  static boolean loopback(String ip) {
    return "127.0.0.1".equals(ip) || "::1".equals(ip)
        || "0:0:0:0:0:0:0:1".equals(ip);
  }

  static String clientIp(HttpServletRequest request) {
    String forwarded = request.getHeader("X-Forwarded-For");
    if (loopback(request.getRemoteAddr()) && forwarded != null) {
      // The local tunnel must append the actual client to the right-hand end.
      String[] chain = forwarded.split(",");
      String ip = chain[chain.length - 1].strip();
      if (ip.length() <= 45 && ip.matches("[0-9a-fA-F:.]+")) return ip;
    }
    return request.getRemoteAddr();
  }

  static String route(String path) {
    return path.replaceFirst("^(/api/(mailbox|receipts|recipients))/[^/]+$", "$1/{id}")
        .replaceFirst("^(/api/admin/revoke)/[^/]+$", "$1/{id}");
  }

  synchronized boolean allow(String key, int limit, long time) {
    attempts.entrySet().removeIf(e -> e.getValue().isEmpty()
        || e.getValue().peekLast() <= time - 60_000_000_000L);
    Deque<Long> q = attempts.get(key);
    if (q == null) {
      if (attempts.size() >= 10000) return false;
      q = new ArrayDeque<>();
      attempts.put(key, q);
    }
    while (!q.isEmpty() && q.peekFirst() <= time - 60_000_000_000L) q.removeFirst();
    if (q.size() >= limit) return false;
    q.addLast(time);
    return true;
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("Cache-Control", "no-store");
    String path = request.getRequestURI();
    if ((path.equals("/") || path.startsWith("/static/") || path.startsWith("/api/admin/"))
        && (!loopback(request.getRemoteAddr())
            || request.getHeader("X-Forwarded-For") != null
            || request.getHeader("X-Forwarded-Host") != null)) {
      error(response, 403, "Open the bank dashboard on the bank computer using localhost");
      return;
    }
    byte[] body = request.getInputStream().readNBytes(16385);
    if (body.length > 16384) {
      error(response, 413, "Request exceeds 16 KB");
      return;
    }
    if (path.startsWith("/api/")) {
      boolean authentication = List.of("/api/login", "/api/signup", "/api/pin").contains(path);
      int limit = authentication ? 60 : 240;
      long time = System.nanoTime();
      if (!allow(clientIp(request) + "|" + route(path), limit, time)) {
        error(response, 429, "Too many requests; retry in a minute");
        return;
      }
      if (authentication) {
        String subject = request.getHeader("Authorization");
        if (!path.equals("/api/pin")) {
          try {
            Object account = parse(new String(body, java.nio.charset.StandardCharsets.UTF_8)).get("account");
            subject = account instanceof String id ? id.strip().toLowerCase(Locale.ROOT) : null;
          } catch (BankException ignored) { }
        }
        if (subject != null && !allow("account|" + path + "|" + digest(subject), 12, time)) {
          error(response, 429, "Too many attempts for this account; retry in a minute");
          return;
        }
      }
    }
    HttpServletRequestWrapper wrapper =
        new HttpServletRequestWrapper(request) {
          @Override
          public ServletInputStream getInputStream() {
            ByteArrayInputStream input = new ByteArrayInputStream(body);
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

              public void setReadListener(ReadListener listener) {
                throw new UnsupportedOperationException();
              }
            };
          }

          @Override
          public BufferedReader getReader() {
            return new BufferedReader(
                new InputStreamReader(getInputStream(), java.nio.charset.StandardCharsets.UTF_8));
          }
        };
    chain.doFilter(wrapper, response);
  }

  static void error(HttpServletResponse r, int code, String detail) throws IOException {
    r.setStatus(code);
    r.setContentType("application/json");
    r.getWriter().write(json(map("detail", detail)));
  }
}
