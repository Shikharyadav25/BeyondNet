"""Install the packaged demo APK on all connected, authorized Android phones."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APK = ROOT / "installers" / "BeyondNet-Android.apk"
PACKAGE = "com.offlinekaro.offline_karo"


def main():
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    adb = shutil.which("adb") or str(sdk / "platform-tools/adb")
    if not Path(adb).is_file():
        sys.exit("Android platform tools are missing. Install them through Android Studio.")
    if not APK.is_file():
        sys.exit("The packaged APK is missing. Follow docs/PHONE_INSTALLATION.md to build it.")
    result = subprocess.run([adb, "devices", "-l"], check=True, capture_output=True, text=True)
    print(result.stdout)
    devices = []
    for row in result.stdout.splitlines()[1:]:
        fields = row.split()
        if len(fields) >= 2 and fields[1] == "device":
            devices.append(fields[0])
    if not devices:
        sys.exit("Connect and unlock your phone, enable USB debugging, and accept its USB debugging prompt. Then run this installer again.")
    failures = []
    for device in devices:
        try:
            api = subprocess.check_output([adb, "-s", device, "shell", "getprop", "ro.build.version.sdk"], text=True).strip()
            if int(api) < 29:
                raise RuntimeError("Android 10 or newer is required")
            print(f"Installing BeyondNet on {device}...")
            subprocess.run([adb, "-s", device, "install", "-r", str(APK)], check=True)
            installed = subprocess.check_output([adb, "-s", device, "shell", "pm", "path", PACKAGE], text=True)
            if "package:" not in installed:
                raise RuntimeError("Package verification failed")
            subprocess.run([adb, "-s", device, "shell", "am", "start", "-W", "-n", PACKAGE + "/.MainActivity"], check=True)
            print("Installed and launched. Complete bank enrollment on the phone.")
        except (subprocess.CalledProcessError, RuntimeError, ValueError) as error:
            failures.append(device)
            print(f"Could not install on {device}: {error}", file=sys.stderr)
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
