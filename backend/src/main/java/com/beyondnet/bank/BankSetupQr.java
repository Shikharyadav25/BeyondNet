package com.beyondnet.bank;

import static com.beyondnet.bank.WireCrypto.*;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.client.j2se.MatrixToImageWriter;
import com.google.zxing.qrcode.QRCodeWriter;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.file.*;
import java.util.Map;

/** Public enrollment configuration. Never includes an operator/account credential. */
public final class BankSetupQr {
  private BankSetupQr() {}

  public static String origin(String value) {
    try {
      URI uri = new URI(value);
      if (value.length() > 500
          || !value.equals(value.strip())
          || !"https".equals(uri.getScheme())
          || uri.getHost() == null
          || uri.getHost().isEmpty()
          || uri.getUserInfo() != null
          || uri.getQuery() != null
          || uri.getFragment() != null
          || (uri.getPort() != -1 && (uri.getPort() < 1 || uri.getPort() > 65535))
          || (uri.getPath() != null && !uri.getPath().isEmpty() && !uri.getPath().equals("/")))
        throw new IllegalArgumentException();
      return value.replaceAll("/+$", "");
    } catch (Exception e) {
      throw new BankException(
          422, "Enter the public bank HTTPS origin, without credentials, path, query or fragment");
    }
  }

  public static String payload(String url, String fingerprint) {
    if (!fingerprint.matches("[a-f0-9]{64}"))
      throw new IllegalArgumentException("Invalid bank fingerprint");
    return json(
        map(
            "type",
            "beyondnet-bank-setup",
            "v",
            1,
            "bank_url",
            origin(url),
            "fingerprint",
            fingerprint));
  }

  public static byte[] png(String url, String fingerprint) {
    String value = payload(url, fingerprint);
    try {
      var matrix =
          new QRCodeWriter()
              .encode(
                  value,
                  BarcodeFormat.QR_CODE,
                  720,
                  720,
                  Map.of(EncodeHintType.MARGIN, 4, EncodeHintType.CHARACTER_SET, "UTF-8"));
      var out = new ByteArrayOutputStream();
      MatrixToImageWriter.writeToStream(matrix, "PNG", out);
      return out.toByteArray();
    } catch (Exception e) {
      throw new IllegalStateException("Could not generate bank setup QR", e);
    }
  }

  public static String publicUrl(Path directory) {
    String url = System.getenv("BEYONDNET_PUBLIC_URL");
    try {
      if (url == null && Files.exists(directory.resolve("public-url.txt")))
        url = Files.readString(directory.resolve("public-url.txt")).strip();
      return url == null ? "" : origin(url);
    } catch (Exception ignored) {
      return "";
    }
  }
}
