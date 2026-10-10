package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import jakarta.annotation.PreDestroy;
import java.util.*;
import java.util.concurrent.*;
import org.springframework.context.annotation.Configuration;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.*;
import org.springframework.web.socket.config.annotation.*;
import org.springframework.web.socket.handler.TextWebSocketHandler;

@Component
public class LiveSocket extends TextWebSocketHandler {
  private final BankService bank;
  private final Map<String, State> clients = new ConcurrentHashMap<>();
  private final ScheduledExecutorService timer =
      Executors.newSingleThreadScheduledExecutor(
          r -> {
            Thread t = new Thread(r, "bank-live-updates");
            t.setDaemon(true);
            return t;
          });

  static class State {
    final WebSocketSession socket;
    final long created = now();
    String token, account, device;
    long cursor = 0, revision = -1, window = now();
    int count = 0;

    State(WebSocketSession s) {
      socket = s;
    }
  }

  public LiveSocket(BankService bank) {
    this.bank = bank;
    timer.scheduleAtFixedRate(
        () -> {
          for (State s : clients.values())
            synchronized (s) {
              try {
                if (s.account == null) {
                  if (now() - s.created >= 10) close(s, 1008);
                } else poll(s);
              } catch (Exception e) {
                close(s, 1008);
              }
            }
        },
        1,
        1,
        TimeUnit.SECONDS);
  }

  @Override
  public void afterConnectionEstablished(WebSocketSession session) {
    session.setTextMessageSizeLimit(16384);
    clients.put(session.getId(), new State(session));
  }

  @Override
  protected void handleTextMessage(WebSocketSession socket, TextMessage message) {
    State s = clients.get(socket.getId());
    if (s == null) return;
    synchronized (s) {
      try {
        if (message.getPayloadLength() > (s.account == null ? 4096 : 16384)) {
          close(s, 1009);
          return;
        }
        Map<String, Object> m = parse(message.getPayload());
        if (s.account == null) {
          s.token = BankService.text(m, "token", 1, 256);
          s.device = BankService.text(m, "device_id", 1, 80);
          s.account = bank.account("Bearer " + s.token);
          bank.db.read(
              c -> {
                bank.checkDevice(c, s.account, s.device);
                return null;
              });
          send(s, map("type", "ready", "fingerprint", bank.trust.get("fingerprint")));
          poll(s);
          return;
        }
        bank.account("Bearer " + s.token);
        bank.db.read(
            c -> {
              bank.checkDevice(c, s.account, s.device);
              return null;
            });
        if (now() - s.window >= 60) {
          s.window = now();
          s.count = 0;
        }
        if (++s.count > 120) {
          close(s, 1008);
          return;
        }
        if (!"submit".equals(m.get("type"))
            || !(m.get("id") instanceof String id)
            || id.length() > 80
            || !(m.get("packet") instanceof Map<?, ?>)) {
          close(s, 1008);
          return;
        }
        try {
          Map<String, Object> result = map("type", "result", "id", id);
          result.putAll(bank.ingest(BankService.object(m.get("packet"))));
          send(s, result);
        } catch (BankException e) {
          send(s, map("type", "error", "id", id, "status", e.status, "message", e.getMessage()));
        }
        poll(s);
      } catch (Exception e) {
        close(s, 1008);
      }
    }
  }

  private void poll(State s) throws Exception {
    bank.account("Bearer " + s.token);
    Map<String, Object> a =
        bank.db.read(
            c -> {
              bank.checkDevice(c, s.account, s.device);
              return bank.snapshot(c, s.account);
            });
    long revision = integer(a.get("revision"));
    if (revision != s.revision) {
      send(s, map("type", "account", "account", a));
      s.revision = revision;
    }
    Map<String, Object> batch = bank.inbox(s.account, s.device, s.cursor);
    if (!((List<?>) batch.get("receipts")).isEmpty()) {
      Map<String, Object> event = map("type", "receipts");
      event.putAll(batch);
      send(s, event);
      s.cursor = integer(batch.get("cursor"));
    }
  }

  private void send(State s, Map<String, Object> data) throws Exception {
    if (s.socket.isOpen()) s.socket.sendMessage(new TextMessage(json(data)));
  }

  private void close(State s, int code) {
    clients.remove(s.socket.getId());
    try {
      s.socket.close(new CloseStatus(code));
    } catch (Exception ignored) {
    }
  }

  @Override
  public void afterConnectionClosed(WebSocketSession socket, CloseStatus status) {
    clients.remove(socket.getId());
  }

  @PreDestroy
  public void stop() {
    timer.shutdownNow();
    for (State s : clients.values()) close(s, 1001);
  }

  @Configuration
  @EnableWebSocket
  public static class Config implements WebSocketConfigurer {
    private final LiveSocket live;

    public Config(LiveSocket live) {
      this.live = live;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
      registry.addHandler(live, "/api/live").setAllowedOriginPatterns("*");
    }
  }
}
