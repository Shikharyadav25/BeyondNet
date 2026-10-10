package com.beyondnet.bank;

import static com.beyondnet.bank.BankDatabase.*;
import static com.beyondnet.bank.WireCrypto.*;

import java.nio.file.*;
import java.sql.Connection;
import java.util.*;
import org.springframework.stereotype.Service;

@Service
public class BankService {
  public final BankDatabase db;
  public final Map<String, Object> trust;
  public volatile boolean online = true;
  private final byte[] signing, encryption;

  public BankService(BankDatabase db) throws Exception {
    this.db = db;
    Path file = db.directory.resolve("bank-keys.json");
    if (!Files.exists(file)
        && (db.read(c -> scalar(c, "SELECT COUNT(*) FROM devices")) > 0
            || db.read(c -> scalar(c, "SELECT COUNT(*) FROM payments")) > 0))
      throw new IllegalStateException(
          "Restore the existing bank-keys.json before opening this enrolled ledger");
    if (!Files.exists(file))
      Files.writeString(
          file,
          json(
              map(
                  "sign",
                  b64(random(32)),
                  "box",
                  b64(random(32)),
                  "mesh_id",
                  HexFormat.of().formatHex(random(16)))),
          StandardOpenOption.CREATE_NEW);
    protect(file, "rw-------");
    Map<String, Object> keys = parse(Files.readString(file));
    signing = unb64((String) keys.get("sign"));
    encryption = unb64((String) keys.get("box"));
    Map<String, Object> t =
        map(
            "sign_key",
            signPublic(signing),
            "box_key",
            boxPublic(encryption),
            "mesh_id",
            keys.get("mesh_id"));
    t.put("fingerprint", digest(t));
    trust = Collections.unmodifiableMap(t);
    System.out.println("BeyondNet Spring Boot bank · fingerprint: " + trust.get("fingerprint"));
    System.out.println("Operator key file: " + db.directory.resolve("admin-token.txt"));
  }

  public Map<String, Object> health() {
    Map<String, Object> h =
        map(
            "service",
            "BeyondNet demo bank",
            "online",
            online,
            "backend",
            "spring-boot",
            "database",
            "postgresql",
            "payment_version",
            2,
            "payment_ttl_seconds",
            600);
    h.putAll(trust);
    return h;
  }

  public static String text(Map<String, Object> m, String key, int min, int max) {
    Object x = m.get(key);
    if (!(x instanceof String s) || s.length() < min || s.length() > max)
      throw new BankException(422, "Invalid " + key);
    return s;
  }

  public static long amount(Map<String, Object> m, String key, long min, long max) {
    try {
      long n = integer(m.get(key));
      if (n < min || n > max) throw new IllegalArgumentException();
      return n;
    } catch (Exception e) {
      throw new BankException(422, "Invalid " + key);
    }
  }

  public static String bearer(String header) {
    return header != null && header.startsWith("Bearer ")
        ? header.substring(7)
        : header == null ? "" : header;
  }

  public String account(String header) {
    return db.read(
        c -> {
          Map<String, Object> r =
              one(
                  c,
                  "SELECT account FROM sessions WHERE token=? AND expiry>?",
                  bearer(header),
                  now());
          if (r == null)
            throw new BankException(401, "Sign in online again; your session has expired");
          return (String) r.get("account");
        });
  }

  public void admin(String header) {
    if (!equal(bearer(header), db.operatorKey))
      throw new BankException(401, "Bank operator key required");
  }

  public Map<String, Object> snapshot(Connection c, String aid) throws Exception {
    Map<String, Object> a = one(c, "SELECT id,name,role,balance FROM accounts WHERE id=?", aid);
    if (a == null) throw new BankException(401, "Account unavailable");
    a.put("revision", scalar(c, "SELECT COALESCE(MAX(id),0) FROM ledger WHERE account=?", aid));
    a.put(
        "pin_configured", one(c, "SELECT account FROM payment_pins WHERE account=?", aid) != null);
    return a;
  }

  public List<Object> merchants(Connection c) throws Exception {
    List<Object> out = new ArrayList<>();
    for (Map<String, Object> r :
        rows(
            c,
            "SELECT d.certificate FROM devices d JOIN accounts a ON a.id=d.account WHERE"
                + " a.role='merchant' AND d.revoked=0"))
      out.add(parse((String) r.get("certificate")));
    return out;
  }

  public Map<String, Object> login(Map<String, Object> body) {
    String aid = text(body, "account", 0, 100).strip().toLowerCase(Locale.ROOT),
        password = text(body, "password", 0, 128);
    return db.tx(
        c -> {
          Map<String, Object> a = one(c, "SELECT * FROM accounts WHERE id=?", aid);
          if (a == null
              || !equal(passwordHash(password, (byte[]) a.get("salt")), (String) a.get("password")))
            throw new BankException(401, "Account or demo password is incorrect");
          String token = token();
          long expiry = now() + 7 * 86400;
          update(c, "DELETE FROM sessions WHERE expiry<?", now());
          update(c, "INSERT INTO sessions VALUES(?,?,?)", token, aid, expiry);
          return map(
              "token",
              token,
              "session_expires_at",
              expiry,
              "account",
              snapshot(c, aid),
              "trust",
              trust);
        });
  }

  public Map<String, Object> signup(Map<String, Object> body) {
    String aid = text(body, "account", 0, 100).strip().toLowerCase(Locale.ROOT),
        password = text(body, "password", 0, 128),
        name = text(body, "name", 1, 60).strip(),
        role = text(body, "role", 1, 20);
    if (!List.of("customer", "merchant").contains(role))
      throw new BankException(422, "Choose customer or merchant");
    if (!aid.matches("[a-z0-9][a-z0-9._-]{2,31}@beyondnet"))
      throw new BankException(
          400, "Use 3–32 letters, digits, dots, underscores or hyphens followed by @beyondnet");
    if (password.length() < 8 || name.isEmpty())
      throw new BankException(400, "Enter a name and a password of at least 8 characters");
    byte[] salt = random(16);
    String hash = passwordHash(password, salt);
    db.tx(
        c -> {
          if (one(c, "SELECT id FROM accounts WHERE id=?", aid) != null)
            throw new BankException(
                409, "This payment ID is already taken. Sign in or choose another ID");
          update(c, "INSERT INTO accounts VALUES(?,?,?,?,?,?)", aid, name, role, 0, salt, hash);
          event(c, "account_created", map("account", aid, "role", role));
          return null;
        });
    return login(body);
  }

  public Map<String, Object> me(String aid) {
    return db.read(c -> map("account", snapshot(c, aid), "merchants", merchants(c)));
  }

  public Map<String, Object> configurePin(String aid, Map<String, Object> body) {
    String pin = text(body, "pin", 6, 6), password = text(body, "password", 8, 128);
    if (!pin.matches("[0-9]{6}")) throw new BankException(422, "Use a six-digit payment PIN");
    return db.tx(
        c -> {
          Map<String, Object> a = one(c, "SELECT * FROM accounts WHERE id=?", aid);
          if (!equal(passwordHash(password, (byte[]) a.get("salt")), (String) a.get("password")))
            throw new BankException(401, "Account password is incorrect");
          byte[] salt = random(16);
          update(
              c,
              "INSERT INTO payment_pins(account,salt,hash,failed,locked_until) VALUES(?,?,?,0,0) ON"
                  + " CONFLICT(account) DO UPDATE SET"
                  + " salt=excluded.salt,hash=excluded.hash,failed=0,locked_until=0",
              aid,
              salt,
              passwordHash(pin, salt));
          event(c, "payment_pin_configured", map("account", aid));
          return map("account", snapshot(c, aid));
        });
  }

  public Map<String, Object> register(String aid, Map<String, Object> b) {
    String did = text(b, "device_id", 16, 80),
        sk = text(b, "sign_key", 1, 64),
        bk = text(b, "box_key", 1, 64),
        proof = text(b, "proof", 1, 100);
    try {
      if (unb64(sk).length != 32 || unb64(bk).length != 32) throw new IllegalArgumentException();
      seal(bk, map("key_check", true));
      verify(
          sk,
          map(
              "body",
              map("device_id", did, "account_id", aid, "sign_key", sk, "box_key", bk),
              "signature",
              proof));
    } catch (Exception e) {
      throw new BankException(400, "Invalid device keys or proof");
    }
    return db.tx(
        c -> {
          Map<String, Object> owner = one(c, "SELECT name,role FROM accounts WHERE id=?", aid);
          Map<String, Object> cert =
              sign(
                  signing,
                  map(
                      "display_name",
                      owner.get("name"),
                      "role",
                      owner.get("role"),
                      "device_id",
                      did,
                      "account_id",
                      aid,
                      "sign_key",
                      sk,
                      "box_key",
                      bk,
                      "mesh_id",
                      trust.get("mesh_id"),
                      "expires_at",
                      now() + 30 * 86400));
          Map<String, Object> old =
              one(c, "SELECT * FROM devices WHERE id=? OR sign_key=?", did, sk);
          if (old != null
              && (!aid.equals(old.get("account"))
                  || !did.equals(old.get("id"))
                  || !sk.equals(old.get("sign_key"))
                  || !bk.equals(old.get("box_key"))
                  || ((Number) old.get("revoked")).intValue() != 0))
            throw new BankException(409, "Device key already registered or revoked");
          if (old == null
              && scalar(c, "SELECT COUNT(*) FROM devices WHERE account=? AND revoked=0", aid) >= 8)
            throw new BankException(
                409, "Demo account device limit reached; revoke an old device first");
          update(
              c,
              "INSERT INTO devices VALUES(?,?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET"
                  + " certificate=excluded.certificate",
              did,
              aid,
              sk,
              bk,
              json(cert));
          event(c, "device_enrolled", map("account", aid, "device_id", did));
          return map("certificate", cert, "merchants", merchants(c));
        });
  }

  public Map<String, Object> recipient(String id) {
    return db.read(
        c -> {
          for (Map<String, Object> r :
              rows(
                  c,
                  "SELECT certificate FROM devices WHERE account=? AND revoked=0 ORDER BY id DESC",
                  id.strip().toLowerCase(Locale.ROOT))) {
            Map<String, Object> cert = parse((String) r.get("certificate"));
            if (integer(object(cert.get("body")).get("expires_at")) > now())
              return map("certificate", cert);
          }
          throw new BankException(
              404, "Recipient not found. Ask them to sign up and enroll their device");
        });
  }

  public Map<String, Object> topup(String aid, Map<String, Object> b) {
    String id = text(b, "request_id", 36, 36);
    try {
      UUID.fromString(id);
    } catch (Exception e) {
      throw new BankException(400, "Invalid top-up request ID");
    }
    long n = amount(b, "amount", 100, 1000000);
    if (!online) throw new BankException(503, "Demo bank is paused; retry this top-up later");
    return db.tx(
        c -> {
          Map<String, Object> old =
              one(c, "SELECT * FROM topups WHERE account=? AND request_id=?", aid, id);
          if (old != null) {
            if (((Number) old.get("amount")).longValue() != n)
              throw new BankException(409, "Top-up ID already used with a different amount");
            return map(
                "account", snapshot(c, aid), "reference", old.get("reference"), "duplicate", true);
          }
          long balance = ((Number) snapshot(c, aid).get("balance")).longValue() + n;
          if (balance > 100000000) throw new BankException(400, "Demo balance limit is ₹10,00,000");
          String ref = reference("DEMO-");
          update(c, "UPDATE accounts SET balance=? WHERE id=?", balance, aid);
          long reserve =
              scalar(c, "SELECT COALESCE(SUM(delta),0) FROM ledger WHERE account='demo-funding'")
                  - n;
          update(
              c,
              "INSERT INTO ledger(payment,account,delta,balance_after,committed) VALUES(?,?,?,?,?)",
              ref,
              "demo-funding",
              -n,
              reserve,
              now());
          update(
              c,
              "INSERT INTO ledger(payment,account,delta,balance_after,committed) VALUES(?,?,?,?,?)",
              ref,
              aid,
              n,
              balance,
              now());
          update(c, "INSERT INTO topups VALUES(?,?,?,?)", aid, id, n, ref);
          event(c, "demo_money_added", map("account", aid, "amount", n, "reference", ref));
          return map("account", snapshot(c, aid), "reference", ref, "duplicate", false);
        });
  }

  static String reference(String prefix) {
    return prefix
        + UUID.randomUUID().toString().replace("-", "").substring(0, 16).toUpperCase(Locale.ROOT);
  }

  @SuppressWarnings("unchecked")
  public static Map<String, Object> object(Object x) {
    if (!(x instanceof Map<?, ?>)) throw new IllegalArgumentException("Object required");
    return (Map<String, Object>) x;
  }

  public Map<String, Object> ingest(Map<String, Object> packet) {
    if (!online)
      throw new BankException(503, "Demo bank connection paused; retain request and retry");
    Map<String, Object> body;
    try {
      checkPacket(packet);
      if (!"payment".equals(packet.get("kind"))) throw new IllegalArgumentException();
      Map<String, Object> signed = openBox(encryption, object(packet.get("box")));
      body = object(signed.get("body"));
      Set<String> fields =
          new HashSet<>(
              List.of(
                  "v",
                  "payment_id",
                  "sender",
                  "recipient",
                  "amount",
                  "currency",
                  "created_at",
                  "expires_at",
                  "device_id",
                  "sender_mailbox",
                  "recipient_mailbox"));
      long version = integer(body.get("v"));
      if (version == 2) fields.add("pin");
      if ((version != 1 && version != 2) || !body.keySet().equals(fields))
        throw new IllegalArgumentException();
      long n = integer(body.get("amount"));
      if (n < 1 || n > 1000000 || !"INR".equals(body.get("currency")))
        throw new IllegalArgumentException();
      for (String key :
          List.of(
              "payment_id",
              "sender",
              "recipient",
              "device_id",
              "sender_mailbox",
              "recipient_mailbox")) text(body, key, 1, 100);
      UUID.fromString((String) body.get("payment_id"));
      if (version == 2 && !text(body, "pin", 6, 6).matches("[0-9]{6}"))
        throw new IllegalArgumentException();
      if (((String) body.get("sender_mailbox")).length() < 32
          || ((String) body.get("recipient_mailbox")).length() < 32
          || body.get("sender_mailbox").equals(body.get("recipient_mailbox")))
        throw new IllegalArgumentException();
      long duration = integer(body.get("expires_at")) - integer(body.get("created_at"));
      if (duration <= 0 || duration > (version == 2 ? 600 : 900))
        throw new IllegalArgumentException();
      Map<String, Object> device =
          db.read(
              c ->
                  one(
                      c,
                      "SELECT * FROM devices WHERE id=? AND account=? AND revoked=0",
                      body.get("device_id"),
                      body.get("sender")));
      if (device == null) throw new IllegalArgumentException();
      verify((String) device.get("sign_key"), signed);
      if (!packet.get("mailbox").equals(body.get("sender_mailbox"))
          || integer(packet.get("expires_at")) != integer(body.get("expires_at")))
        throw new IllegalArgumentException();
    } catch (Exception e) {
      throw new BankException(
          400, "Payment validation failed: invalid packet, signature or encrypted instruction");
    }
    // The signed instruction, not a route or gateway identity, owns the financial idempotency key.
    String requestHash = digest(body);
    return db.tx(
        c -> {
          Map<String, Object> existing =
              one(
                  c,
                  "SELECT * FROM payments WHERE sender=? AND id=?",
                  body.get("sender"),
                  body.get("payment_id"));
          if (existing != null) {
            if (!requestHash.equals(existing.get("hash")))
              throw new BankException(
                  409, "Payment ID was already used for a different instruction");
            event(
                c,
                "duplicate_recovered",
                map("payment_id", body.get("payment_id"), "status", existing.get("status")));
            return map(
                "duplicate",
                true,
                "receipts",
                JSON.readValue((String) existing.get("receipts"), List.class));
          }
          Map<String, Object> d =
              one(c, "SELECT * FROM devices WHERE id=? AND revoked=0", body.get("device_id"));
          if (d == null) throw new BankException(400, "Sender device was revoked");
          Map<String, Object>
              sender = one(c, "SELECT * FROM accounts WHERE id=?", body.get("sender")),
              recipient = one(c, "SELECT * FROM accounts WHERE id=?", body.get("recipient"));
          List<Map<String, Object>> targets =
              rows(c, "SELECT * FROM devices WHERE account=? AND revoked=0", body.get("recipient"));
          if (sender == null
              || recipient == null
              || targets.isEmpty()
              || body.get("sender").equals(body.get("recipient")))
            throw new BankException(400, "Recipient must be a different enrolled account");
          long timestamp = now(), n = integer(body.get("amount"));
          String reason = "";
          if (integer(body.get("created_at")) > timestamp + 60)
            reason = "Device clock is ahead of the bank";
          else if (integer(body.get("expires_at")) <= timestamp)
            reason = "Authorization expired before bank submission";
          else if (integer(body.get("v")) != 2)
            reason = "Update BeyondNet and set a payment PIN before making new payments";
          else
            reason = checkPin(c, (String) body.get("sender"), (String) body.get("pin"), timestamp);
          if (reason.isEmpty() && ((Number) sender.get("balance")).longValue() < n)
            reason = "Insufficient demo balance";
          String status = reason.isEmpty() ? "paid" : "rejected", ref = reference("OK-");
          if (status.equals("paid")) {
            for (Map<String, Object> a : List.of(sender, recipient)) {
              long delta = a == sender ? -n : n,
                  balance = ((Number) a.get("balance")).longValue() + delta;
              update(c, "UPDATE accounts SET balance=? WHERE id=?", balance, a.get("id"));
              update(
                  c,
                  "INSERT INTO ledger(payment,account,delta,balance_after,committed)"
                      + " VALUES(?,?,?,?,?)",
                  ref,
                  a.get("id"),
                  delta,
                  balance,
                  timestamp);
            }
          }
          List<Map<String, Object>> receipts = new ArrayList<>();
          List<Map<String, Object>> devices = new ArrayList<>();
          devices.add(d);
          devices.addAll(targets);
          List<?> reverse = new ArrayList<>((List<?>) packet.get("path"));
          Collections.reverse(reverse);
          for (Map<String, Object> device : devices) {
            Map<String, Object> a = snapshot(c, (String) device.get("account"));
            Map<String, Object> result =
                sign(
                    signing,
                    map(
                        "v",
                        1,
                        "payment_id",
                        body.get("payment_id"),
                        "sender",
                        body.get("sender"),
                        "recipient",
                        body.get("recipient"),
                        "amount",
                        n,
                        "currency",
                        "INR",
                        "status",
                        status,
                        "reason",
                        reason,
                        "bank_ref",
                        ref,
                        "committed_at",
                        timestamp,
                        "device_id",
                        device.get("id"),
                        "balance",
                        a.get("balance"),
                        "balance_revision",
                        a.get("revision")));
            String cap = (String) body.get(device == d ? "sender_mailbox" : "recipient_mailbox");
            Map<String, Object> receipt =
                packet(
                    "receipt",
                    seal((String) device.get("box_key"), result),
                    cap,
                    timestamp + 7 * 86400,
                    reverse);
            receipts.add(receipt);
            update(
                c,
                "INSERT INTO device_receipts(device,packet_id,packet,expiry) VALUES(?,?,?,?)",
                device.get("id"),
                receipt.get("id"),
                json(receipt),
                receipt.get("expires_at"));
          }
          String encoded = json(receipts);
          update(
              c,
              "INSERT INTO payments VALUES(?,?,?,?,?,?,?,?,?,?)",
              body.get("sender"),
              body.get("payment_id"),
              requestHash,
              body.get("recipient"),
              n,
              status,
              reason,
              ref,
              timestamp,
              encoded);
          for (String key : List.of("sender_mailbox", "recipient_mailbox")) {
            String cap = (String) body.get(key);
            List<Map<String, Object>> owned =
                key.equals("sender_mailbox")
                    ? receipts
                    : receipts.stream().filter(x -> cap.equals(x.get("mailbox"))).toList();
            update(
                c,
                "INSERT INTO mailboxes VALUES(?,?,?) ON CONFLICT(capability) DO UPDATE SET"
                    + " receipts=excluded.receipts,expiry=excluded.expiry",
                cap,
                json(owned),
                timestamp + 7 * 86400);
          }
          event(
              c,
              "bank_decision",
              map(
                  "payment_id",
                  body.get("payment_id"),
                  "sender",
                  body.get("sender"),
                  "recipient",
                  body.get("recipient"),
                  "amount",
                  n,
                  "status",
                  status,
                  "reason",
                  reason,
                  "bank_ref",
                  ref));
          return map("duplicate", false, "receipts", receipts);
        });
  }

  private String checkPin(Connection c, String aid, String pin, long time) throws Exception {
    Map<String, Object> row = one(c, "SELECT * FROM payment_pins WHERE account=?", aid);
    if (row == null) return "Set your payment PIN online before paying";
    if (((Number) row.get("locked_until")).longValue() > time)
      return "Payment PIN is temporarily locked; retry a new payment after 10 minutes";
    if (!equal(passwordHash(pin, (byte[]) row.get("salt")), (String) row.get("hash"))) {
      int failures = ((Number) row.get("failed")).intValue() + 1;
      update(
          c,
          "UPDATE payment_pins SET failed=?,locked_until=? WHERE account=?",
          failures,
          failures >= 5 ? time + 600 : 0,
          aid);
      return "Payment PIN is incorrect";
    }
    update(c, "UPDATE payment_pins SET failed=0,locked_until=0 WHERE account=?", aid);
    return "";
  }

  public void checkDevice(Connection c, String aid, String did) throws Exception {
    if (one(c, "SELECT id FROM devices WHERE id=? AND account=? AND revoked=0", did, aid) == null)
      throw new BankException(403, "Device is not registered or has been revoked");
  }

  public Map<String, Object> inbox(String aid, String did, long after) {
    return db.read(
        c -> {
          checkDevice(c, aid, did);
          long cursor = Math.max(0, after);
          List<Map<String, Object>> r =
              rows(
                  c,
                  "SELECT seq,packet FROM device_receipts WHERE device=? AND seq>? AND expiry>?"
                      + " ORDER BY seq LIMIT 50",
                  did,
                  cursor,
                  now());
          List<Object> packets = new ArrayList<>();
          for (Map<String, Object> x : r) packets.add(parse((String) x.get("packet")));
          return map("receipts", packets, "cursor", r.isEmpty() ? cursor : r.getLast().get("seq"));
        });
  }

  public Map<String, Object> mailbox(String cap) {
    return db.read(
        c -> {
          Map<String, Object> r =
              one(c, "SELECT receipts FROM mailboxes WHERE capability=? AND expiry>?", cap, now());
          return map(
              "receipts",
              r == null ? List.of() : JSON.readValue((String) r.get("receipts"), List.class));
        });
  }

  public Map<String, Object> state() {
    return db.read(
        c -> {
          List<Map<String, Object>> events =
              rows(c, "SELECT * FROM events ORDER BY id DESC LIMIT 100");
          for (Map<String, Object> e : events) e.put("detail", parse((String) e.get("detail")));
          return map(
              "online",
              online,
              "trust",
              trust,
              "public_url",
              BankSetupQr.publicUrl(db.directory),
              "metrics",
              map(
                  "paid_count",
                  scalar(c, "SELECT COUNT(*) FROM payments WHERE status='paid'"),
                  "volume",
                  scalar(c, "SELECT COALESCE(SUM(amount),0) FROM payments WHERE status='paid'")),
              "accounts",
              rows(c, "SELECT id,name,role,balance FROM accounts"),
              "devices",
              rows(c, "SELECT id,account,revoked FROM devices"),
              "payments",
              rows(
                  c,
                  "SELECT id,sender,recipient,amount,status,reason,bank_ref,committed FROM payments"
                      + " ORDER BY committed DESC LIMIT 60"),
              "ledger",
              rows(c, "SELECT * FROM ledger ORDER BY id DESC LIMIT 120"),
              "events",
              events);
        });
  }

  public Map<String, Object> revoke(String did) {
    return db.tx(
        c -> {
          update(c, "UPDATE devices SET revoked=1 WHERE id=?", did);
          event(c, "device_revoked", map("device_id", did));
          return map("revoked", true);
        });
  }
}
