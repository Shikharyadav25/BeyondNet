package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;
import static com.beyondnet.bank.BankDatabase.*;
import java.util.*;
import org.springframework.stereotype.Service;

/** Campus data is namespaced away from payment accounts, packets and ledger. */
@Service
public class CampusService {
  final BankDatabase db;
  public CampusService(BankDatabase db) {
    this.db = db;
    db.tx(c -> {
      update(c, "CREATE TABLE IF NOT EXISTS campus_config(code TEXT PRIMARY KEY, data TEXT NOT NULL)");
      update(c, "CREATE TABLE IF NOT EXISTS campus_packets(seq BIGSERIAL PRIMARY KEY, id TEXT UNIQUE NOT NULL, campus TEXT NOT NULL, expiry BIGINT NOT NULL, data TEXT NOT NULL)");
      update(c, "CREATE INDEX IF NOT EXISTS campus_packets_feed ON campus_packets(campus,seq)");
      return null;
    });
  }
  static void require(boolean ok, String message) {
    if (!ok) throw new BankException(400, message);
  }
  @SuppressWarnings("unchecked") static Map<String,Object> obj(Object o) {
    require(o instanceof Map, "Expected object"); return (Map<String,Object>) o;
  }
  static String text(Map<String,Object> o, String k, int max) {
    Object v=o.get(k); require(v instanceof String && !((String)v).isBlank() && ((String)v).length()<=max, "Invalid " + k);
    return (String)v;
  }
  static List<String> strings(Object o) {
    require(o instanceof List && ((List<?>)o).size()<=64, "Invalid groups");
    return ((List<?>)o).stream().map(x -> {require(x instanceof String && ((String)x).matches("[a-zA-Z0-9_-]{1,64}"), "Invalid group ID"); return (String)x;}).toList();
  }
  Map<String,Object> config(String code) {
    return db.read(c -> {var r=one(c,"SELECT data FROM campus_config WHERE code=?",code);
      if(r==null) throw new BankException(404,"Campus code not found"); return parse((String)r.get("data"));});
  }
  public Object provision(Map<String,Object> input) {
    String code=text(input,"code",32).toUpperCase(Locale.ROOT);
    require(code.matches("[A-Z0-9-]{3,32}"),"Invalid campus code");
    String name=text(input,"name",100);
    Map<String,Object> groups=obj(input.get("groups"));
    require(!groups.isEmpty() && groups.size()<=32,"Use 1 to 32 groups");
    var keys=new LinkedHashMap<String,Object>();
    for(var entry:groups.entrySet()) {
      strings(List.of(entry.getKey())); var g=obj(entry.getValue());
      String kind=text(g,"kind",20);
      require(List.of("section","faculty","authority").contains(kind),"Invalid group kind");
      keys.put(entry.getKey(),map("name",text(g,"name",100),"kind",kind,"key",b64(random(32))));
    }
    require(input.get("members") instanceof List,"Members required");
    var members=new LinkedHashMap<String,Object>();
    var roster=(List<?>)input.get("members"); require(roster.size()<=2000,"Roster exceeds 2000 members");
    for(Object raw:roster) {
      var m=obj(raw); String id=text(m,"id",80), role=text(m,"role",20), password=text(m,"password",128);
      require(password.length()>=10,"Use campus passwords of at least 10 characters");
      require(List.of("student","professor","hod","authority").contains(role),"Invalid role");
      var assigned=strings(m.get("groups")); require(keys.keySet().containsAll(assigned),"Unknown group");
      require(!members.containsKey(id),"Duplicate member"); byte[] salt=random(16);
      members.put(id,map("id",id,"name",text(m,"name",100),"role",role,"groups",assigned,"salt",b64(salt),"password",passwordHash(password,salt)));
    }
    byte[] seed=random(32);
    var cfg=map("code",code,"name",name,"seed",b64(seed),"public_key",signPublic(seed),"groups",keys,"members",members);
    db.tx(c -> {require(one(c,"SELECT code FROM campus_config WHERE code=?",code)==null,"Campus already exists; use a new code for a new roster epoch");
      update(c,"INSERT INTO campus_config VALUES(?,?)",code,json(cfg));return null;});
    return map("code",code,"name",name,"public_key",signPublic(seed),"fingerprint",hash(unb64(signPublic(seed))));
  }
  public Object discover(String code) {
    var c=config(code); return map("code",code,"name",c.get("name"),"public_key",c.get("public_key"));
  }
  public Object enroll(Map<String,Object> input) {
    var c=config(text(input,"code",32)); String id=text(input,"id",80), password=text(input,"password",128);
    var member=obj(c.get("members")).get(id);
    var m=member==null?Map.<String,Object>of():obj(member);
    String hash=passwordHash(password,member==null?new byte[16]:unb64((String)m.get("salt")));
    if(member==null || !equal(hash,(String)m.get("password"))) throw new BankException(401,"Campus ID or password is incorrect");
    String pub=text(input,"public_key",100); require(unb64(pub).length==32,"Invalid device key");
    var read=strings(m.get("groups")); var write=new ArrayList<String>(); var visible=new LinkedHashMap<String,Object>();
    for(String idg:read) {
      var g=obj(obj(c.get("groups")).get(idg)); visible.put(idg,g);
      String kind=(String)g.get("kind"), role=(String)m.get("role");
      if(kind.equals("section") || kind.equals("faculty") && !role.equals("student") || kind.equals("authority") && List.of("hod","authority").contains(role)) write.add(idg);
    }
    long now=System.currentTimeMillis()/1000;
    var cert=sign(unb64((String)c.get("seed")),map("type","beyondnet/campus-member/v1","campus",c.get("code"),"id",id,"name",m.get("name"),"role",m.get("role"),"public_key",pub,"read",read,"write",write,"issued_at",now,"expires_at",now+86400));
    return map("certificate",cert,"groups",visible,"name",c.get("name"));
  }
  Map<String,Object> membership(Map<String,Object> cfg, Object raw) {
    var m=verify((String)cfg.get("public_key"),obj(raw));
    require("beyondnet/campus-member/v1".equals(m.get("type")) && cfg.get("code").equals(m.get("campus")),"Wrong campus identity");
    require(((Number)m.get("expires_at")).longValue()>System.currentTimeMillis()/1000,"Renew campus access online"); return m;
  }
  public Object sync(Map<String,Object> input) {
    try {
      var cfg=config(text(input,"code",32)); var request=obj(input.get("request")); var cert=obj(input.get("certificate"));
      var m=membership(cfg,cert); var b=verify((String)m.get("public_key"),request);
      long now=System.currentTimeMillis()/1000;
      require("beyondnet/campus-sync/v1".equals(b.get("type")) && cfg.get("code").equals(b.get("campus")) && Math.abs(((Number)b.get("at")).longValue()-now)<=120,"Invalid sync request");
      Object offered=b.get("packet"); String accepted=null;
      if(offered!=null) {
        var p=obj(offered); var sender=membership(cfg,p.get("certificate")); var body=verify((String)sender.get("public_key"),obj(p.get("signed")));
        require("beyondnet/campus-message/v1".equals(body.get("type")) && cfg.get("code").equals(body.get("campus")),"Invalid campus message");
        require(List.of(0,1).contains(body.get("priority")),"Invalid message priority");
        require(!Integer.valueOf(1).equals(body.get("priority")) || List.of("hod","authority").contains(sender.get("role")),"Only campus authorities can send urgent messages");
        String group=text(body,"group",64); require(strings(sender.get("write")).contains(group),"Sender cannot post to this group");
        require(strings(sender.get("read")).contains(group),"Sender cannot read this group");
        long created=((Number)body.get("created_at")).longValue(), expiry=((Number)body.get("expires_at")).longValue();
        require(created<=now+120 && created>=((Number)sender.get("issued_at")).longValue() && expiry>now && expiry>created && expiry<=created+86400 && expiry<=((Number)sender.get("expires_at")).longValue(),"Invalid message lifetime");
        require(canonical(p).length<=8192 && digest(p.get("signed")).equals(p.get("id")),"Invalid message ID or size");
        var box=obj(body.get("box")); require(unb64(text(box,"nonce",32)).length==12 && unb64(text(box,"ciphertext",6000)).length>=16,"Invalid encrypted message");
        accepted=(String)p.get("id"); final String id=accepted;
        db.tx(c -> {update(c,"DELETE FROM campus_packets WHERE expiry<=?",now); require(scalar(c,"SELECT COUNT(*) FROM campus_packets WHERE campus=?",cfg.get("code"))<100000 || one(c,"SELECT id FROM campus_packets WHERE id=?",id)!=null,"Campus queue full"); update(c,"INSERT INTO campus_packets(id,campus,expiry,data) VALUES(?,?,?,?) ON CONFLICT(id) DO NOTHING",id,cfg.get("code"),expiry,json(p)); return null;});
      }
      long after=((Number)b.get("after")).longValue(); require(after>=0,"Invalid cursor");
      var feed=db.read(c -> rows(c,"SELECT seq,data FROM campus_packets WHERE campus=? AND seq>? AND expiry>? ORDER BY seq LIMIT 1",cfg.get("code"),after,now));
      var response=map("type","beyondnet/campus-receipt/v1","request_id",b.get("request_id"),"accepted",accepted,"after",feed.isEmpty()?after:feed.getFirst().get("seq"),"packet",feed.isEmpty()?null:parse((String)feed.getFirst().get("data")));
      return sign(unb64((String)cfg.get("seed")),response);
    } catch(BankException e) {throw e;} catch(Exception e) {throw new BankException(400,"Invalid campus envelope");}
  }
}
