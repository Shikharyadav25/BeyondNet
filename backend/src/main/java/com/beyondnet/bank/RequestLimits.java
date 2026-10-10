package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import jakarta.servlet.*;
import jakarta.servlet.http.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class RequestLimits extends OncePerRequestFilter {
  private final Map<String, Deque<Long>> attempts = new ConcurrentHashMap<>();

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("Cache-Control", "no-store");
    byte[] body = request.getInputStream().readNBytes(16385);
    if (body.length > 16384) {
      error(response, 413, "Request exceeds 16 KB");
      return;
    }
    String path = request.getRequestURI();
    if (path.startsWith("/api/")) {
      int limit = List.of("/api/login", "/api/signup", "/api/pin").contains(path) ? 12 : 240;
      long time = System.nanoTime();
      Deque<Long> q =
          attempts.computeIfAbsent(request.getRemoteAddr() + "|" + path, k -> new ArrayDeque<>());
      synchronized (q) {
        while (!q.isEmpty() && q.peekFirst() < time - 60_000_000_000L) q.removeFirst();
        if (q.size() >= limit) {
          error(response, 429, "Too many requests; retry in a minute");
          return;
        }
        q.addLast(time);
      }
      if (attempts.size() > 10000)
        attempts
            .entrySet()
            .removeIf(
                e -> {
                  synchronized (e.getValue()) {
                    return e.getValue().isEmpty()
                        || e.getValue().peekLast() < time - 60_000_000_000L;
                  }
                });
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
