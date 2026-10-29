package com.beyondnet.bank;
import static com.beyondnet.bank.WireCrypto.*;
import static com.beyondnet.bank.BankDatabase.*;
import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Path;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;

class CampusServiceTest {
  @TempDir Path dir;
  BankDatabase db;
  CampusService service;
  byte[] studentKey, professorKey, hodKey;
  Map<String,Object> student, professor, hod;
  @BeforeEach void setup() {
    db=new BankDatabase(dir); service=new CampusService(db);
    service.provision(map("code","CAMPUS-1","name","Test College","groups",map(
      "s1",map("name","Section A","kind","section"),
      "f1",map("name","Faculty assignments","kind","faculty"),
      "n1",map("name","College notices","kind","authority")),
      "members",List.of(member("erp-1","student"),member("prof-1","professor"),member("hod-1","hod"))));
    studentKey=random(32); professorKey=random(32); hodKey=random(32);
    student=enroll("erp-1",studentKey); professor=enroll("prof-1",professorKey); hod=enroll("hod-1",hodKey);
  }
  Map<String,Object> member(String id,String role) {return map("id",id,"name",id,"role",role,"password","campus-test-password","groups",List.of("s1","f1","n1"));}
  Map<String,Object> enroll(String id,byte[] key) {return CampusService.obj(service.enroll(map("code","CAMPUS-1","id",id,"password","campus-test-password","public_key",signPublic(key))));}
  Map<String,Object> packet(Map<String,Object> user,byte[] key,String group,long expiry) {
    long now=System.currentTimeMillis()/1000;
    var signed=sign(key,map("type","beyondnet/campus-message/v1","campus","CAMPUS-1","group",group,"created_at",now,"expires_at",expiry,"priority",0,"nonce_id",token(),"box",map("nonce",b64(random(12)),"ciphertext",b64(random(40)))));
    return map("id",digest(signed),"signed",signed,"certificate",user.get("certificate"));
  }
  Map<String,Object> sync(Map<String,Object> user,byte[] key,Object packet,long after) {
    String nonce=token();
    var result=CampusService.obj(service.sync(map("code","CAMPUS-1","certificate",user.get("certificate"),"request",sign(key,map("type","beyondnet/campus-sync/v1","campus","CAMPUS-1","at",System.currentTimeMillis()/1000,"request_id",nonce,"after",after,"packet",packet)))));
    var receipt=verify((String)service.config("CAMPUS-1").get("public_key"),result);
    assertEquals(nonce,receipt.get("request_id"));return receipt;
  }
  long expiry(Map<String,Object> user) {return ((Number)CampusService.obj(CampusService.obj(user.get("certificate")).get("body")).get("expires_at")).longValue();}
  @AfterEach void close() {if(db!=null){db.dropTestSchema();db.close();}}
  @Test void rosterControlsRolesAndGroupWrites() {
    var s=CampusService.obj(CampusService.obj(student.get("certificate")).get("body"));
    assertEquals("student",s.get("role")); assertEquals(List.of("s1"),s.get("write"));
    var p=CampusService.obj(CampusService.obj(professor.get("certificate")).get("body"));
    assertEquals(List.of("s1","f1"),p.get("write"));
    var h=CampusService.obj(CampusService.obj(hod.get("certificate")).get("body"));
    assertEquals(List.of("s1","f1","n1"),h.get("write"));
    assertThrows(BankException.class,()->service.enroll(map("code","CAMPUS-1","id","erp-1","password","wrong","public_key",signPublic(studentKey))));
  }
  @Test void studentCannotImpersonateStaffOrPostNotices() {
    assertThrows(BankException.class,()->sync(student,studentKey,packet(student,studentKey,"f1",expiry(student)),0));
    assertThrows(BankException.class,()->sync(student,studentKey,packet(student,studentKey,"n1",expiry(student)),0));
    assertThrows(BankException.class,()->sync(professor,professorKey,packet(professor,professorKey,"n1",expiry(professor)),0));
    assertThrows(BankException.class,()->sync(student,professorKey,null,0));
  }
  @Test void durableIdempotentStoreAndCursorFeedAreSeparateFromLedger() {
    var p=packet(hod,hodKey,"n1",expiry(hod));
    var r=sync(hod,hodKey,p,0); assertEquals(p.get("id"),r.get("accepted"));
    sync(hod,hodKey,p,0);
    assertEquals(1L,db.<Long>read(c->scalar(c,"SELECT COUNT(*) FROM campus_packets")).longValue());
    service=new CampusService(db);
    var feed=sync(student,studentKey,null,0); assertEquals(p.get("id"),CampusService.obj(feed.get("packet")).get("id"));
    assertNull(sync(student,studentKey,null,((Number)feed.get("after")).longValue()).get("packet"));
    assertEquals(0L,db.<Long>read(c->scalar(c,"SELECT COUNT(*) FROM ledger")).longValue());
  }
  @Test void rejectsTamperingExpiredLifetimeAndWrongCampus() {
    var p=packet(student,studentKey,"s1",expiry(student)); p.put("id","forged");
    assertThrows(BankException.class,()->sync(student,studentKey,p,0));
    assertThrows(BankException.class,()->sync(student,studentKey,packet(student,studentKey,"s1",System.currentTimeMillis()/1000-1),0));
    assertThrows(BankException.class,()->sync(student,studentKey,packet(student,studentKey,"s1",expiry(student)+1),0));
    var forged=CampusService.obj(CampusService.obj(student.get("certificate")).get("body")); forged.put("role","hod");
    assertThrows(BankException.class,()->sync(student,studentKey,null,0));
  }
  @Test void operatorCannotSilentlyOverwriteCampusTrustOrRoster() {
    assertThrows(BankException.class,()->service.provision(map("code","CAMPUS-1","name","Other","groups",map("s1",map("name","Section","kind","section")),"members",List.of(member("erp-1","student")))));
  }
}
