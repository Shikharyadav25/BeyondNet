package com.beyondnet.bank;

import static org.junit.jupiter.api.Assertions.*;
import static com.beyondnet.bank.WireCrypto.*;
import java.io.ByteArrayInputStream;
import javax.imageio.ImageIO;
import com.google.zxing.*;
import com.google.zxing.client.j2se.BufferedImageLuminanceSource;
import com.google.zxing.common.HybridBinarizer;
import org.junit.jupiter.api.Test;

class CampusSetupQrTest {
  @Test void publicPsitQrRoundTripsWithoutCredentials() throws Exception {
    String payload=CampusSetupQr.payload("https://psit.example/", "PSIT-KANPUR", "ab".repeat(32));
    var image=ImageIO.read(new ByteArrayInputStream(CampusSetupQr.png(payload)));
    var decoded=new MultiFormatReader().decode(new BinaryBitmap(new HybridBinarizer(new BufferedImageLuminanceSource(image))));
    assertEquals(payload,decoded.getText());
    var setup=parse(payload);
    assertEquals(5,setup.size());
    assertEquals("beyondnet-campus-setup",setup.get("type"));
    assertEquals("PSIT-KANPUR",setup.get("code"));
    assertEquals("https://psit.example",setup.get("campus_url"));
    assertFalse(payload.contains("password"));
  }
  @Test void rejectsInsecureOrAmbiguousSetup() {
    assertThrows(BankException.class,()->CampusSetupQr.payload("http://psit.example","PSIT-KANPUR","ab".repeat(32)));
    assertThrows(BankException.class,()->CampusSetupQr.payload("https://psit.example/path","PSIT-KANPUR","ab".repeat(32)));
    assertThrows(BankException.class,()->CampusSetupQr.payload("https://psit.example","../campus","ab".repeat(32)));
  }
}
