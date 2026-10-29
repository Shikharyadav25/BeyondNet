package com.beyondnet.bank;

import static com.beyondnet.bank.BankDatabase.*;
import static com.beyondnet.bank.WireCrypto.*;
import jakarta.annotation.PreDestroy;
import java.util.concurrent.*;
import org.springframework.stereotype.Component;

/** Bounded housekeeping; payment outcomes and ledger entries are never deleted. */
@Component
@org.springframework.context.annotation.Profile("!campus")
public final class BankMaintenance {
  private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor(r -> {
    Thread t = new Thread(r, "bank-housekeeping"); t.setDaemon(true); return t;
  });
  public BankMaintenance(BankDatabase db) {
    timer.scheduleWithFixedDelay(() -> {
      try {
        db.read(c -> {
          for (String table : java.util.List.of("sessions", "mailboxes", "device_receipts"))
            update(c, "DELETE FROM " + table + " WHERE ctid IN (SELECT ctid FROM " + table
                + " WHERE expiry<? LIMIT 1000)", now());
          update(c, "DELETE FROM events WHERE id IN (SELECT id FROM events WHERE at<? LIMIT 1000)",
              now() - 90 * 86400);
          return null;
        });
      } catch (Exception e) {
        org.slf4j.LoggerFactory.getLogger(BankMaintenance.class)
            .warn("Bank housekeeping delayed ({})", e.getClass().getSimpleName());
      }
    }, 1, 15, TimeUnit.MINUTES);
  }
  @PreDestroy public void close() { timer.shutdownNow(); }
}
