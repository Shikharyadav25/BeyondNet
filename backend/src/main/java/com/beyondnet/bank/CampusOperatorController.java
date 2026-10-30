package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;
import org.springframework.context.annotation.Profile;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;

@RestController
@Profile("campus")
public class CampusOperatorController {
  @org.springframework.beans.factory.annotation.Value("${CAMPUS_PUBLIC_URL}")
  private String publicUrl;
  @org.springframework.beans.factory.annotation.Value("${CAMPUS_CODE:PSIT-KANPUR}")
  private String campusCode;
  private final CampusService campus;
  private final BankDatabase db;
  public CampusOperatorController(CampusService campus, BankDatabase db) {this.campus=campus;this.db=db;}
  @GetMapping("/api/campus-health") public Object health() {
    db.read(c -> BankDatabase.scalar(c, "SELECT 1"));
    return map("service","BeyondNet PSIT Kanpur campus","online",true,"database","postgresql");
  }
  void admin(String header) {
    if (!equal(BankService.bearer(header), db.operatorKey)) throw new BankException(401,"Campus operator key required");
  }
  String setup(String header, String code, String url) {
    admin(header);
    var c=campus.config(code);
    return CampusSetupQr.payload(url, code, hash(unb64((String)c.get("public_key"))));
  }
  @GetMapping("/api/admin/campus/{code}/setup") public Object setupJson(
      @RequestHeader(value="Authorization",required=false) String h, @PathVariable String code,
      @RequestParam String campus_url) {return parse(setup(h,code,campus_url));}
  @GetMapping(value="/api/admin/campus/{code}/setup.png", produces=MediaType.IMAGE_PNG_VALUE)
  public byte[] qr(@RequestHeader(value="Authorization",required=false) String h,
      @PathVariable String code, @RequestParam String campus_url) {
    return CampusSetupQr.png(setup(h,code,campus_url));
  }
  @GetMapping(value="/", produces=MediaType.TEXT_HTML_VALUE) public String home() {
    return """
      <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>PSIT Kanpur Campus</title><style>body{font:18px system-ui;max-width:760px;margin:40px auto;padding:20px;background:#f2faf8;color:#14352f}input,button{font:inherit;padding:12px;margin:8px 0;width:95%}img{max-width:100%}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style>
      <h1>PSIT Kanpur Campus</h1><p>BeyondNet demonstration server. Use generated Campus credentials; this is not an official PSIT ERP integration.</p>
      <p>Enter your operator key to generate the campus enrollment QR. Your campus and connection are already configured.</p>
      <label>Campus operator key<input id="key" type="password" autocomplete="off"></label>
      <button id="generate">Generate campus setup QR</button><p id="status" role="status"></p><img id="qr" alt="Campus enrollment QR" hidden><pre id="details"></pre>
      <script>
      const setupConfig=__CAMPUS_SETUP_CONFIG__;
      let previous;document.getElementById('generate').onclick=async()=>{
        const status=document.getElementById('status');status.textContent='Generating…';
        document.getElementById('qr').hidden=true;document.getElementById('details').textContent='';
        try{const code=encodeURIComponent(setupConfig.code);
          const query='?campus_url='+encodeURIComponent(setupConfig.url);
          const headers={Authorization:'Bearer '+document.getElementById('key').value.trim()};
          const base='/api/admin/campus/'+code+'/setup';
          const response=await fetch(base+query,{headers});const data=await response.json();
          if(!response.ok)throw Error(data.detail||'Setup failed');
          const image=await fetch(base+'.png'+query,{headers});if(!image.ok)throw Error('QR generation failed');
          if(previous)URL.revokeObjectURL(previous);previous=URL.createObjectURL(await image.blob());
          document.getElementById('qr').src=previous;document.getElementById('qr').hidden=false;
          document.getElementById('details').textContent=JSON.stringify(data,null,2);
          status.textContent='Scan in Campus → Scan college setup QR. Share only with trusted demo participants.';
        }catch(e){status.textContent=e.message;}};
      </script></html>
      """.replace("__CAMPUS_SETUP_CONFIG__", json(map("code", campusCode, "url", publicUrl)).replace("<", "\\u003c"));
  }
  @ExceptionHandler(BankException.class) public ResponseEntity<?> error(BankException e) {
    return ResponseEntity.status(e.status).body(map("detail",e.getMessage()));
  }
}
