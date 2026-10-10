package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import java.util.*;
import org.springframework.core.io.ClassPathResource;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
public class BankController {
  private final BankService bank;
  private final RehearsalService rehearsal;

  public BankController(BankService bank, RehearsalService rehearsal) {
    this.bank = bank;
    this.rehearsal = rehearsal;
  }

  @GetMapping("/")
  public ClassPathResource dashboard() {
    return new ClassPathResource("static/index.html");
  }

  @GetMapping("/api/health")
  public Object health() {
    return bank.health();
  }

  @PostMapping("/api/login")
  public Object login(@RequestBody Map<String, Object> b) {
    return bank.login(b);
  }

  @PostMapping("/api/signup")
  public Object signup(@RequestBody Map<String, Object> b) {
    return bank.signup(b);
  }

  @GetMapping("/api/me")
  public Object me(@RequestHeader(value = "Authorization", required = false) String h) {
    return bank.me(bank.account(h));
  }

  @PostMapping("/api/pin")
  public Object pin(
      @RequestHeader(value = "Authorization", required = false) String h,
      @RequestBody Map<String, Object> b) {
    return bank.configurePin(bank.account(h), b);
  }

  @PostMapping("/api/devices")
  public Object register(
      @RequestHeader(value = "Authorization", required = false) String h,
      @RequestBody Map<String, Object> b) {
    return bank.register(bank.account(h), b);
  }

  @PostMapping("/api/topups")
  public Object topup(
      @RequestHeader(value = "Authorization", required = false) String h,
      @RequestBody Map<String, Object> b) {
    return bank.topup(bank.account(h), b);
  }

  @GetMapping("/api/recipients/{id}")
  public Object recipient(
      @RequestHeader(value = "Authorization", required = false) String h, @PathVariable String id) {
    bank.account(h);
    return bank.recipient(id);
  }

  @PostMapping("/api/packets")
  public Object ingest(
      @RequestHeader(value = "Authorization", required = false) String h,
      @RequestBody Map<String, Object> b) {
    bank.account(h);
    return bank.ingest(b);
  }

  @GetMapping("/api/mailbox/{cap}")
  public Object mailbox(
      @RequestHeader(value = "Authorization", required = false) String h,
      @PathVariable String cap) {
    bank.account(h);
    return bank.mailbox(cap);
  }

  @GetMapping("/api/receipts/{id}")
  public Object receipts(
      @RequestHeader(value = "Authorization", required = false) String h,
      @PathVariable String id,
      @RequestParam(defaultValue = "0") long after) {
    return bank.inbox(bank.account(h), id, after);
  }

  @PostMapping(value = "/api/admin/setup-qr", produces = "image/png")
  public byte[] setupQr(
      @RequestHeader(value = "Authorization", required = false) String h,
      @RequestBody Map<String, Object> b) {
    bank.admin(h);
    return BankSetupQr.png(
        BankService.text(b, "bank_url", 1, 500), (String) bank.trust.get("fingerprint"));
  }

  @GetMapping("/api/admin/state")
  public Object state(@RequestHeader(value = "Authorization", required = false) String h) {
    bank.admin(h);
    return bank.state();
  }

  @PostMapping("/api/admin/connection")
  public Object connection(
      @RequestHeader(value = "Authorization", required = false) String h,
      @RequestBody Map<String, Object> b) {
    bank.admin(h);
    if (!(b.get("online") instanceof Boolean online))
      throw new BankException(400, "online must be a boolean");
    bank.online = online;
    return map("online", online);
  }

  @PostMapping("/api/admin/revoke/{id}")
  public Object revoke(
      @RequestHeader(value = "Authorization", required = false) String h, @PathVariable String id) {
    bank.admin(h);
    return bank.revoke(id);
  }

  @PostMapping("/api/admin/rehearsal")
  public Object rehearsal(@RequestHeader(value = "Authorization", required = false) String h) {
    bank.admin(h);
    return rehearsal.run();
  }

  @ExceptionHandler(BankException.class)
  public ResponseEntity<?> error(BankException e) {
    return ResponseEntity.status(e.status).body(map("detail", e.getMessage()));
  }

  @ExceptionHandler(org.springframework.http.converter.HttpMessageNotReadableException.class)
  public ResponseEntity<?> invalidJson() {
    return ResponseEntity.badRequest().body(map("detail", "Invalid JSON body"));
  }

  @ExceptionHandler(Exception.class)
  public ResponseEntity<?> unexpected(Exception e) {
    return ResponseEntity.internalServerError()
        .body(map("detail", "Bank could not complete this request; retain it and retry"));
  }
}
