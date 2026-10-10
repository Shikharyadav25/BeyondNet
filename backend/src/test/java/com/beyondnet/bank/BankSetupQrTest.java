package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;
import static org.junit.jupiter.api.Assertions.*;

import com.google.zxing.*;
import com.google.zxing.client.j2se.BufferedImageLuminanceSource;
import com.google.zxing.common.HybridBinarizer;
import java.io.ByteArrayInputStream;
import javax.imageio.ImageIO;
import org.junit.jupiter.api.Test;

class BankSetupQrTest {
  @Test
  void generatedPngDecodesToBothPublicFieldsAndNoSecrets() throws Exception {
    String fingerprint = "a".repeat(64), url = "https://bank.example";
    var png = BankSetupQr.png(url + "/", fingerprint);
    var image = ImageIO.read(new ByteArrayInputStream(png));
    var text =
        new MultiFormatReader()
            .decode(new BinaryBitmap(new HybridBinarizer(new BufferedImageLuminanceSource(image))))
            .getText();
    assertEquals(
        map("type", "beyondnet-bank-setup", "v", 1, "bank_url", url, "fingerprint", fingerprint),
        parse(text));
    assertEquals(720, image.getWidth());
    assertEquals(720, image.getHeight());
  }

  @Test
  void insecureOrCredentialBearingUrlsAreRejected() {
    for (String url :
        java.util.List.of(
            "http://bank.example",
            "https://a:b@bank.example",
            "https://bank.example/api",
            "https://bank.example?token=secret",
            "https://bank.example#fragment",
            " https://bank.example",
            "https://bank.example:99999"))
      assertEquals(
          422,
          assertThrows(BankException.class, () -> BankSetupQr.png(url, "a".repeat(64))).status);
  }
}
