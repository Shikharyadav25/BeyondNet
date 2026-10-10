package com.beyondnet.bank;

import static com.beyondnet.bank.BankDatabase.*;
import static com.beyondnet.bank.WireCrypto.*;
import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;

class BankServiceTest {
  @TempDir Path directory;
  BankDatabase db;
  BankService bank;
  byte[] sk, bk, mk, mb;
  String did, mid;
  final String payer = "payer@beyondnet",
      merchant = "merchant@beyondnet",
      password = "demo-password";

  @BeforeEach
  void setup() throws Exception {
    db = new BankDatabase(directory);
    bank = new BankService(db);
    bank.signup(map("account", payer, "password", password, "name", "Payer", "role", "customer"));
    bank.signup(
        map("account", merchant, "password", password, "name", "Merchant", "role", "merchant"));
    bank.configurePin(payer, map("pin", "123456", "password", password));
    sk = random(32);
    bk = random(32);
    mk = random(32);
    mb = random(32);
    did = UUID.randomUUID().toString();
    mid = UUID.randomUUID().toString();
    enroll(payer, did, sk, bk);
    enroll(merchant, mid, mk, mb);
    bank.topup(payer, map("amount", 100000, "request_id", UUID.randomUUID().toString()));
  }

  @AfterEach
  void close() {
    if (db != null) {
      db.dropTestSchema();
      db.close();
    }
  }

  void enroll(String aid, String id, byte[] sign, byte[] box) {
    Map<String, Object> identity =
        map(
            "device_id",
            id,
            "account_id",
            aid,
            "sign_key",
            signPublic(sign),
            "box_key",
            boxPublic(box));
    bank.register(
        aid,
        map(
            "device_id",
            id,
            "sign_key",
            signPublic(sign),
            "box_key",
            boxPublic(box),
            "proof",
            sign(sign, identity).get("signature")));
  }

  Map<String, Object> body(long amount) {
    long time = now();
    return map(
        "v",
        2,
        "payment_id",
        UUID.randomUUID().toString(),
        "sender",
        payer,
        "recipient",
        merchant,
        "amount",
        amount,
        "currency",
        "INR",
        "created_at",
        time,
        "expires_at",
        time + 600,
        "device_id",
        did,
        "sender_mailbox",
        HexFormat.of().formatHex(random(24)),
        "recipient_mailbox",
        HexFormat.of().formatHex(random(24)),
        "pin",
        "123456");
  }

  Map<String, Object> wrap(Map<String, Object> body) {
    return wrap(body, sk);
  }

  Map<String, Object> wrap(Map<String, Object> body, byte[] key) {
    return packet(
        "payment",
        seal((String) bank.trust.get("box_key"), sign(key, body)),
        (String) body.get("sender_mailbox"),
        integer(body.get("expires_at")),
        List.of(did, "relay"));
  }

  Map<String, Object> receipt(Map<String, Object> result) {
    Map<String, Object> p = BankService.object(((List<?>) result.get("receipts")).getFirst());
    return verify(
        (String) bank.trust.get("sign_key"), openBox(bk, BankService.object(p.get("box"))));
  }

  long balance(String id) {
    return db.read(c -> scalar(c, "SELECT balance FROM accounts WHERE id=?", id));
  }

  long payments() {
    return db.read(c -> scalar(c, "SELECT COUNT(*) FROM payments"));
  }

  @Test
  void pythonFixtureCanonicalSignatureAndEncryption() throws Exception {
    Map<String, Object> f =
        parse(Files.readString(Path.of("../mobile/test/fixtures/python-wire.json")));
    assertEquals(
        f.get("canonical"),
        new String(canonical(f.get("body")), java.nio.charset.StandardCharsets.UTF_8));
    assertEquals(
        f.get("signed"),
        sign(unb64((String) f.get("sign_seed")), BankService.object(f.get("body"))));
    assertEquals(
        f.get("signed"),
        openBox(unb64((String) f.get("box_seed")), BankService.object(f.get("box"))));
    checkPacket(BankService.object(f.get("packet")));
  }

  @Test
  void paymentImmediatelySettlesAndPinIsNotStored() {
    Map<String, Object> result = bank.ingest(wrap(body(1000)));
    assertEquals("paid", receipt(result).get("status"));
    assertEquals(99000, balance(payer));
    assertEquals(1000, balance(merchant));
    db.read(
        c -> {
          assertEquals(0, scalar(c, "SELECT SUM(delta) FROM ledger"));
          String stored =
              json(rows(c, "SELECT * FROM payments"))
                  + json(rows(c, "SELECT * FROM events"))
                  + json(rows(c, "SELECT * FROM device_receipts"));
          assertFalse(stored.contains("\"pin\""));
          assertFalse(stored.contains("123456"));
          return null;
        });
  }

  @Test
  void concurrentDuplicateGatewaysDebitExactlyOnce() throws Exception {
    Map<String, Object> p = wrap(body(1000));
    ExecutorService pool = Executors.newFixedThreadPool(8);
    try {
      List<Callable<Map<String, Object>>> work = new ArrayList<>();
      for (int i = 0; i < 16; i++) work.add(() -> bank.ingest(p));
      List<Future<Map<String, Object>>> results = pool.invokeAll(work);
      int first = 0;
      String receipts = null;
      for (Future<Map<String, Object>> r : results) {
        Map<String, Object> x = r.get();
        if (!Boolean.TRUE.equals(x.get("duplicate"))) first++;
        String encoded = json(x.get("receipts"));
        if (receipts == null) receipts = encoded;
        else assertEquals(receipts, encoded);
      }
      assertEquals(1, first);
      assertEquals(1, payments());
      assertEquals(99000, balance(payer));
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void reencryptionAndRouteChangesRecoverSameDecision() {
    Map<String, Object> b = body(1000), first = bank.ingest(wrap(b)), p = wrap(b);
    p.put("path", List.of("other-gateway"));
    p.put("hops", 3);
    Map<String, Object> again = bank.ingest(p);
    assertEquals(true, again.get("duplicate"));
    assertEquals(json(first.get("receipts")), json(again.get("receipts")));
    assertEquals(1, payments());
  }

  @Test
  void anotherDeviceCannotReusePaymentIdForDifferentInstruction() {
    Map<String, Object> b = body(1000);
    bank.ingest(wrap(b));
    byte[] second = random(32);
    String id = UUID.randomUUID().toString();
    enroll(payer, id, second, random(32));
    b.put("device_id", id);
    BankException e = assertThrows(BankException.class, () -> bank.ingest(wrap(b, second)));
    assertEquals(409, e.status);
    assertEquals(1, payments());
  }

  @Test
  void concurrentSpendingCannotOverspend() throws Exception {
    Map<String, Object> p = wrap(body(70000)), q = wrap(body(70000));
    ExecutorService pool = Executors.newFixedThreadPool(2);
    try {
      List<Future<Map<String, Object>>> out =
          pool.invokeAll(List.of(() -> bank.ingest(p), () -> bank.ingest(q)));
      List<String> statuses = new ArrayList<>();
      for (Future<Map<String, Object>> r : out)
        statuses.add((String) receipt(r.get()).get("status"));
      Collections.sort(statuses);
      assertEquals(List.of("paid", "rejected"), statuses);
      assertEquals(30000, balance(payer));
      assertEquals(70000, balance(merchant));
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void tamperingCannotMutateBalances() {
    Map<String, Object> p = wrap(body(1000));
    p.put("expires_at", now() + 1000);
    assertEquals(400, assertThrows(BankException.class, () -> bank.ingest(p)).status);
    assertEquals(0, payments());
    Map<String, Object> b = body(1000);
    assertEquals(400, assertThrows(BankException.class, () -> bank.ingest(wrap(b, mk))).status);
    Map<String, Object> ct = wrap(b);
    BankService.object(ct.get("box")).put("ciphertext", "AAAA");
    ct.put(
        "id",
        digest(
            map(
                "v",
                ct.get("v"),
                "kind",
                ct.get("kind"),
                "mailbox",
                ct.get("mailbox"),
                "box",
                ct.get("box"),
                "expires_at",
                ct.get("expires_at"))));
    assertEquals(400, assertThrows(BankException.class, () -> bank.ingest(ct)).status);
    assertEquals(100000, balance(payer));
  }

  @Test
  void ttlRejectsOnlyUnprocessedExpiredRequests() {
    Map<String, Object> b = body(1000);
    b.put("created_at", now() - 700);
    b.put("expires_at", now() - 100);
    assertEquals("rejected", receipt(bank.ingest(wrap(b))).get("status"));
    assertEquals(100000, balance(payer));
    Map<String, Object> tooLong = body(1000);
    tooLong.put("expires_at", integer(tooLong.get("created_at")) + 601);
    assertEquals(400, assertThrows(BankException.class, () -> bank.ingest(wrap(tooLong))).status);
  }

  @Test
  void wrongPinDuplicatesDoNotConsumeExtraAttemptsAndLockPersists() {
    Map<String, Object> b = body(1000);
    b.put("pin", "000000");
    Map<String, Object> p = wrap(b);
    bank.ingest(p);
    bank.ingest(p);
    assertEquals(
        1L,
        db.<Long>read(c -> scalar(c, "SELECT failed FROM payment_pins WHERE account=?", payer)));
    for (int i = 0; i < 4; i++) {
      Map<String, Object> q = body(1000);
      q.put("pin", "000000");
      bank.ingest(wrap(q));
    }
    assertTrue(((String) receipt(bank.ingest(wrap(body(1000)))).get("reason")).contains("locked"));
    assertEquals(100000, balance(payer));
    assertTrue(
        db.read(c -> scalar(c, "SELECT locked_until FROM payment_pins WHERE account=?", payer))
            > now());
  }

  @Test
  void oldProtocolCannotBypassPinButStoredOldReceiptsRemainRecoverable() {
    Map<String, Object> b = body(1000);
    b.put("v", 1);
    b.remove("pin");
    assertEquals("rejected", receipt(bank.ingest(wrap(b))).get("status"));
    assertEquals(100000, balance(payer));
  }

  @Test
  void restartRetainsIdentityLedgerPinAndReceipt() throws Exception {
    Map<String, Object> p = wrap(body(1000)), result = bank.ingest(p);
    String fingerprint = (String) bank.trust.get("fingerprint"), operator = db.operatorKey;
    String namespace = db.namespace();
    db.close();
    db = new BankDatabase(directory, namespace);
    bank = new BankService(db);
    assertEquals(fingerprint, bank.trust.get("fingerprint"));
    assertEquals(operator, db.operatorKey);
    Map<String, Object> retry = bank.ingest(p);
    assertEquals(true, retry.get("duplicate"));
    assertEquals(json(result.get("receipts")), json(retry.get("receipts")));
    assertEquals(99000, balance(payer));
    assertEquals(true, db.read(c -> bank.snapshot(c, payer)).get("pin_configured"));
  }

  @Test
  void concurrentTopupCreditsOnce() throws Exception {
    String id = UUID.randomUUID().toString();
    ExecutorService pool = Executors.newFixedThreadPool(4);
    try {
      List<Callable<Map<String, Object>>> work = new ArrayList<>();
      for (int i = 0; i < 8; i++)
        work.add(() -> bank.topup(payer, map("amount", 1000, "request_id", id)));
      int first = 0;
      for (Future<Map<String, Object>> r : pool.invokeAll(work))
        if (!Boolean.TRUE.equals(r.get().get("duplicate"))) first++;
      assertEquals(1, first);
      assertEquals(101000, balance(payer));
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void accountPasswordRequiredToSetOrResetPin() {
    assertEquals(
        401,
        assertThrows(
                BankException.class,
                () -> bank.configurePin(payer, map("pin", "111111", "password", "wrong-password")))
            .status);
    assertEquals(
        422,
        assertThrows(
                BankException.class,
                () -> bank.configurePin(payer, map("pin", "123", "password", password)))
            .status);
  }

  @Test
  void revocationBlocksNewInstruction() {
    bank.revoke(did);
    assertEquals(
        400, assertThrows(BankException.class, () -> bank.ingest(wrap(body(1000)))).status);
    assertEquals(100000, balance(payer));
  }

  @Test
  void databaseLockProtectsSeparateBankInstances() throws Exception {
    Path other = directory.resolve("other-instance");
    Files.createDirectories(other);
    Files.copy(directory.resolve("bank-keys.json"), other.resolve("bank-keys.json"));
    try (BankDatabase second = new BankDatabase(other, db.namespace())) {
      BankService service = new BankService(second);
      Map<String, Object> p = wrap(body(1000));
      ExecutorService pool = Executors.newFixedThreadPool(2);
      try {
        List<Future<Map<String, Object>>> results =
            pool.invokeAll(List.of(() -> bank.ingest(p), () -> service.ingest(p)));
        long first = 0;
        for (var result : results) if (!Boolean.TRUE.equals(result.get().get("duplicate"))) first++;
        assertEquals(1, first);
        assertEquals(99000, balance(payer));
        assertEquals(1, payments());
      } finally {
        pool.shutdownNow();
      }
    }
  }

  @Test
  void completedPaymentRemainsPaidAfterAuthorizationExpires() throws Exception {
    Map<String, Object> b = body(1000);
    // Allow the first commit to cross a remote database network before testing late recovery.
    long deadline = now() + 30;
    b.put("created_at", deadline - 600);
    b.put("expires_at", deadline);
    Map<String, Object> p = wrap(b), result = bank.ingest(p);
    assertEquals("paid", receipt(result).get("status"));
    while (now() < integer(b.get("expires_at"))) Thread.sleep(100);
    Map<String, Object> recovered = bank.ingest(p);
    assertEquals(true, recovered.get("duplicate"));
    assertEquals(json(result.get("receipts")), json(recovered.get("receipts")));
    assertEquals(99000, balance(payer));
  }

  @Test
  void lowOrderRecipientEncryptionKeyIsRejected() {
    String id = UUID.randomUUID().toString(), key = b64(new byte[32]);
    byte[] secret = random(32);
    Map<String, Object> identity =
        map(
            "device_id",
            id,
            "account_id",
            merchant,
            "sign_key",
            signPublic(secret),
            "box_key",
            key);
    assertEquals(
        400,
        assertThrows(
                BankException.class,
                () ->
                    bank.register(
                        merchant,
                        map(
                            "device_id",
                            id,
                            "sign_key",
                            signPublic(secret),
                            "box_key",
                            key,
                            "proof",
                            sign(secret, identity).get("signature"))))
            .status);
  }

  @Test
  void importRefusesPopulatedUnmarkedTargetAndPreservesBalances() throws Exception {
    Path old = directory.resolve("old.sqlite3");
    try (var c = java.sql.DriverManager.getConnection("jdbc:sqlite:" + old)) {
      execute(c, "CREATE TABLE accounts(id TEXT PRIMARY KEY)");
    }
    assertThrows(
        RuntimeException.class,
        () ->
            db.tx(
                c -> {
                  LegacySqliteImport.importInto(c, old);
                  return null;
                }));
    assertEquals(100000, balance(payer));
    assertEquals(0, payments());
  }

  @Test
  void receiptPersistenceFailureRollsBackEntirePayment() {
    db.tx(
        c -> {
          update(c, "DROP TABLE device_receipts");
          return null;
        });
    assertThrows(RuntimeException.class, () -> bank.ingest(wrap(body(1000))));
    assertEquals(100000, balance(payer));
    assertEquals(0, balance(merchant));
    assertEquals(0, payments());
  }
}
