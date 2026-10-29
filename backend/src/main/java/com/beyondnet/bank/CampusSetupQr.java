package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;
import java.io.ByteArrayOutputStream;
import java.util.Map;
import com.google.zxing.*;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.client.j2se.MatrixToImageWriter;

/** Public campus trust bootstrap; passwords and operator keys never enter this QR. */
public final class CampusSetupQr {
  private CampusSetupQr() {}
  public static String payload(String url, String code, String fingerprint) {
    if (!code.matches("[A-Z0-9-]{3,32}") || !fingerprint.matches("[a-f0-9]{64}"))
      throw new BankException(422, "Invalid campus code or fingerprint");
    return json(map("type", "beyondnet-campus-setup", "v", 1,
        "campus_url", BankSetupQr.origin(url), "code", code, "fingerprint", fingerprint));
  }
  public static byte[] png(String payload) {
    try {
      var matrix = new QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, 720, 720,
          Map.of(EncodeHintType.MARGIN, 4, EncodeHintType.CHARACTER_SET, "UTF-8"));
      var out = new ByteArrayOutputStream();
      MatrixToImageWriter.writeToStream(matrix, "PNG", out);
      return out.toByteArray();
    } catch (Exception e) {throw new IllegalStateException("Could not generate campus QR", e);}
  }
}
