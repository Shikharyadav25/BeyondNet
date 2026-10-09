"""Share only the signed APK and its checksum with phones on local Wi-Fi."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import html
import socket

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "installers"
APK = FILES / "BeyondNet-Android.apk"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(FILES), **kwargs)

    def do_GET(self):
        if self.path == "/":
            size = APK.stat().st_size / 1_000_000
            body = f"""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Install BeyondNet</title>
<style>body{{margin:0;background:#f1f5f3;color:#12332c;font:17px/1.55 system-ui,sans-serif}}main{{max-width:540px;margin:8vh auto;padding:30px;background:white;border-radius:24px}}h1{{font-size:36px;line-height:1.15}}small{{color:#526c64}}a.download{{display:block;background:#087f69;color:white;padding:18px;text-align:center;border-radius:14px;text-decoration:none;font-weight:700}}li{{margin:14px 0}}footer{{border-top:1px solid #e2ebe7;padding-top:18px;font-size:14px}}@media(max-width:600px){{main{{margin:20px;padding:24px}}}}</style>
<main><small>BEYONDNET · ANDROID DEMO</small><h1>Your phone is ready for the next step.</h1>
<p>Install the native app on each Android phone. Android 10 or newer is required. For nearby payments on Android 10–11, allow Location while using BeyondNet and keep Location switched on.</p>
<a class="download" href="/BeyondNet-Android.apk">Download app · {size:.1f} MB</a>
<ol><li>Open the downloaded APK.</li><li>If Android asks, allow this browser to install apps, then tap <strong>Install</strong>.</li><li>Open <strong>BeyondNet</strong>, enroll against your bank's HTTPS address and verified fingerprint while online, and complete the permissions setup.</li></ol>
<footer>This is a development-signed demo build using demo money. <a href="/SHA256SUMS.txt">APK checksum</a></footer></main></html>""".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path in ("/BeyondNet-Android.apk", "/SHA256SUMS.txt"):
            super().do_GET()
        else:
            self.send_error(404)

    def do_HEAD(self):
        if self.path in ("/BeyondNet-Android.apk", "/SHA256SUMS.txt"):
            super().do_HEAD()
        else:
            self.send_error(404)

    def list_directory(self, path):
        self.send_error(404)

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        if self.path == "/BeyondNet-Android.apk":
            self.send_header("Content-Disposition", 'attachment; filename="BeyondNet-Android.apk"')
        super().end_headers()

    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".apk": "application/vnd.android.package-archive"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not APK.is_file():
        parser.error("The packaged Android APK is missing.")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.connect(("8.8.8.8", 80))
        address = connection.getsockname()[0]
    print(f"On phones using this Mac's Wi-Fi, open http://{address}:{args.port}/", flush=True)
    print("Sharing the APK and checksum only. Press Control-C to stop.", flush=True)
    with ThreadingHTTPServer(("0.0.0.0", args.port), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
