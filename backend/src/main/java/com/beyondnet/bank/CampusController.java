package com.beyondnet.bank;
import java.util.Map;
import org.springframework.web.bind.annotation.*;
@RestController
public class CampusController {
  private final CampusService campus;
  private final BankDatabase db;
  public CampusController(CampusService campus, BankDatabase db) {this.campus=campus;this.db=db;}
  @PostMapping("/api/admin/campuses") public Object provision(@RequestHeader(value="Authorization",required=false) String h,@RequestBody Map<String,Object> b) {if (!WireCrypto.equal(BankService.bearer(h), db.operatorKey)) throw new BankException(401,"Campus operator key required");return campus.provision(b);}
  @GetMapping("/api/campus/{code}") public Object discover(@PathVariable String code) {return campus.discover(code);}
  @PostMapping("/api/campus/enroll") public Object enroll(@RequestBody Map<String,Object> b) {return campus.enroll(b);}
  @PostMapping("/api/campus/sync") public Object sync(@RequestBody Map<String,Object> b) {return campus.sync(b);}
  @ExceptionHandler(BankException.class) public org.springframework.http.ResponseEntity<?> error(BankException e) {return org.springframework.http.ResponseEntity.status(e.status).body(WireCrypto.map("detail",e.getMessage()));}
  @ExceptionHandler({IllegalArgumentException.class,ClassCastException.class,NullPointerException.class}) public org.springframework.http.ResponseEntity<?> invalid() {return org.springframework.http.ResponseEntity.badRequest().body(WireCrypto.map("detail","Invalid campus request"));}
}
