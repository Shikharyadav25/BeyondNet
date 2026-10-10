package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import java.util.*;
import org.springframework.stereotype.Service;

/** Isolated rehearsal ACCOUNTS in the same ledger, never a physical Bluetooth claim. */
@Service
public class RehearsalService {
  private final BankService bank;

  public RehearsalService(BankService bank) {
    this.bank = bank;
  }

  public Map<String, Object> run() {
    String suffix = UUID.randomUUID().toString().substring(0, 8),
        payer = "sim-payer-" + suffix + "@beyondnet",
        merchant = "sim-shop-" + suffix + "@beyondnet",
        password = token();
    bank.signup(
        map(
            "account",
            payer,
            "name",
            "Rehearsal sender",
            "role",
            "customer",
            "password",
            password));
    bank.signup(
        map(
            "account",
            merchant,
            "name",
            "Rehearsal merchant",
            "role",
            "merchant",
            "password",
            password));
    bank.configurePin(payer, map("pin", "123456", "password", password));
    bank.topup(payer, map("amount", 100000, "request_id", UUID.randomUUID().toString()));
    byte[] sk = random(32), bk = random(32), ms = random(32), mb = random(32);
    String did = UUID.randomUUID().toString(), mid = UUID.randomUUID().toString();
    enroll(payer, did, sk, bk);
    enroll(merchant, mid, ms, mb);
    long time = now();
    String cap = HexFormat.of().formatHex(random(24));
    Map<String, Object> body =
        map(
            "v",
            2,
            "payment_id",
            UUID.randomUUID().toString(),
            "sender",
            payer,
            "recipient",
            merchant,
            "amount",
            12500,
            "currency",
            "INR",
            "created_at",
            time,
            "expires_at",
            time + 600,
            "device_id",
            did,
            "sender_mailbox",
            cap,
            "recipient_mailbox",
            HexFormat.of().formatHex(random(24)),
            "pin",
            "123456");
    Map<String, Object> p =
        packet(
            "payment",
            seal((String) bank.trust.get("box_key"), sign(sk, body)),
            cap,
            time + 600,
            List.of(did, "simulated-relay"));
    p.put("hops", 2);
    Map<String, Object> result = bank.ingest(p);
    Map<String, Object> receipt = BankService.object(((List<?>) result.get("receipts")).getFirst());
    Map<String, Object> decoded =
        verify(
            (String) bank.trust.get("sign_key"),
            openBox(bk, BankService.object(receipt.get("box"))));
    boolean duplicate = Boolean.TRUE.equals(bank.ingest(p).get("duplicate"));
    return map(
        "trace",
        List.of(
            "Software-only sender and merchant enrolled; no phone radio used.",
            "Sender added demo money and configured a test PIN.",
            "Payment signed, encrypted and assigned a 10-minute lifetime.",
            "Simulated relay path carried ciphertext to the Java bank.",
            "Bank verified sender, PIN and authorization before atomic settlement.",
            "Encrypted bank receipt returned on the simulated reverse path.",
            "Sender decrypted and verified the bank signature.",
            "Repeated submission recovered the same result without another debit."),
        "receipt",
        decoded,
        "duplicate",
        duplicate);
  }

  private void enroll(String aid, String did, byte[] sk, byte[] bk) {
    Map<String, Object> identity =
        map(
            "device_id",
            did,
            "account_id",
            aid,
            "sign_key",
            signPublic(sk),
            "box_key",
            boxPublic(bk));
    Map<String, Object> b =
        map(
            "device_id",
            did,
            "sign_key",
            signPublic(sk),
            "box_key",
            boxPublic(bk),
            "proof",
            sign(sk, identity).get("signature"));
    bank.register(aid, b);
  }
}
