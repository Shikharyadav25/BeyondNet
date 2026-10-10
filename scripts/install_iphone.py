"""Build, sign, install, and launch on one connected physical iPhone."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / "mobile"


def flutter_path():
    path = shutil.which("flutter")
    if path:
        return path
    properties = MOBILE / "android/local.properties"
    if properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith("flutter.sdk="):
                candidate = Path(line.split("=", 1)[1]) / "bin/flutter"
                if candidate.is_file():
                    return str(candidate)
    sys.exit("Flutter is missing. Install Flutter and add its bin folder to PATH.")


def apple_team(explicit):
    if explicit:
        return explicit
    result = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True)
    teams = set()
    def visit(value):
        if isinstance(value, dict):
            identifier = value.get("teamID")
            if isinstance(identifier, str) and re.fullmatch(r"[A-Z0-9]{10}", identifier):
                teams.add(identifier)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    if result.returncode == 0:
        visit(plistlib.loads(result.stdout).get("IDEProvisioningTeamByIdentifier", {}))
    if len(teams) != 1:
        sys.exit("Sign in to Xcode → Settings → Accounts. If you have multiple teams, run this script with --team YOUR_TEAM_ID.")
    return next(iter(teams))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team")
    parser.add_argument("--device")
    options = parser.parse_args()
    if sys.platform != "darwin":
        sys.exit("iPhone installation requires macOS and Xcode.")
    flutter = flutter_path()
    devices = json.loads(subprocess.check_output([flutter, "devices", "--machine"], cwd=MOBILE, text=True))
    phones = [device for device in devices if device.get("targetPlatform") == "ios" and not device.get("emulator")]
    if options.device:
        phones = [device for device in phones if device["id"] == options.device]
    if len(phones) != 1:
        sys.exit("Connect and unlock one iPhone, approve Trust This Computer, and enable Developer Mode. For multiple iPhones, specify --device DEVICE_ID.")
    team = apple_team(options.team)
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        sys.exit("Apple team IDs must contain 10 uppercase letters/digits.")
    device = phones[0]["id"]
    bundle = f"com.offlinekaro.demo.{team.lower()}"
    print(f"Building for {phones[0]['name']} with Apple team {team}...", flush=True)
    subprocess.run([flutter, "build", "ios", "--release", "--no-codesign"], cwd=MOBILE, check=True)
    output = MOBILE / "build/ios/iphoneos"
    subprocess.run([
        "xcodebuild", "-workspace", "Runner.xcworkspace", "-scheme", "Runner",
        "-configuration", "Release", "-destination", f"id={device}",
        "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
        f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES",
        f"PRODUCT_BUNDLE_IDENTIFIER={bundle}", f"CONFIGURATION_BUILD_DIR={output}", "build",
    ], cwd=MOBILE / "ios", check=True)
    app = output / "Runner.app"
    if not app.is_dir():
        sys.exit("Xcode did not produce Runner.app; installation was not attempted.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", device, str(app)], check=True)
    subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", device, bundle], check=True)
    print("Installed and launched on the iPhone. Complete bank enrollment and permissions on the phone.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError:
        sys.exit("The build or installation failed. Follow docs/PHONE_INSTALLATION.md; no successful installation is claimed.")
