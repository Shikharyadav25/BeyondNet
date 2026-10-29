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
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;

@Component
@org.springframework.context.annotation.Profile("!campus")
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
  private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
  private final Runnable committed = () -> clients.values().forEach(this::queuePoll);

  static class State {
    final WebSocketSession socket;
    final long created = now();
    String token, device;
    volatile String account;
    long cursor = 0, revision = -1, window = now();
    volatile long lastPoll = 0;
    int count = 0;
    final java.util.concurrent.atomic.AtomicBoolean queued = new java.util.concurrent.atomic.AtomicBoolean();
    volatile boolean dirty;

    State(WebSocketSession s) {
      socket = s;
    }
  }

  public LiveSocket(BankService bank) {
    this.bank = bank;
    bank.db.commitListeners.add(committed);
    timer.scheduleAtFixedRate(
        () -> {
          for (State s : clients.values()) {
            if (s.account == null) {
              if (now() - s.created >= 10) close(s, 1008);
            } else if (now() - s.lastPoll >= 30) queuePoll(s);
          }
        },
        1,
        1,
        TimeUnit.SECONDS);
  }

  @Override
  public void afterConnectionEstablished(WebSocketSession session) {
    session.setTextMessageSizeLimit(16384);
    synchronized (clients) {
      if (clients.size() >= 128) {
        try { session.close(new CloseStatus(1013)); } catch (Exception ignored) { }
        return;
      }
      clients.put(session.getId(), new State(new ConcurrentWebSocketSessionDecorator(session, 10000, 131072)));
    }
  }

  private void queuePoll(State s) {
    s.dirty = true;
    if (!s.queued.compareAndSet(false, true)) return;
    workers.execute(() -> {
      try {
        for (int i = 0; i < 4 && s.dirty && clients.containsKey(s.socket.getId()); i++) {
          s.dirty = false;
          synchronized (s) {
            if (s.account != null) poll(s);
          }
        }
      } catch (Exception e) {
        close(s, 1008);
      } finally {
        s.queued.set(false);
        if (s.dirty && clients.containsKey(s.socket.getId())) queuePoll(s);
      }
    });
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
          if (m.containsKey("after")) s.cursor = Math.max(0, integer(m.get("after")));
          s.account = bank.account("Bearer " + s.token);
          bank.db.read(
              c -> {
                bank.checkDevice(c, s.account, s.device);
                return null;
              });
          send(s, map("type", "ready", "fingerprint", bank.trust.get("fingerprint")));
          queuePoll(s);
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
        queuePoll(s);
      } catch (Exception e) {
        close(s, 1008);
      }
    }
  }

  private void poll(State s) throws Exception {
    s.lastPoll = now();
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
      if (((List<?>) batch.get("receipts")).size() == 50) s.dirty = true;
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
    bank.db.commitListeners.remove(committed);
    timer.shutdownNow();
    workers.shutdownNow();
    for (State s : clients.values()) close(s, 1001);
  }

  @Configuration
  @org.springframework.context.annotation.Profile("!campus")
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
