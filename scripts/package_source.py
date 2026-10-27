"""Package source and documentation, excluding runtime data, secrets, and caches."""
from pathlib import Path
import zipfile
ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'dist'/'BeyondNet-source.zip'
OUTPUT.parent.mkdir(exist_ok=True)
EXCLUDED={'dist','target','.git','.kotlin','.venv','data','build','.dart_tool','.gradle','.cxx','.pytest_cache','__pycache__','Pods','.symlinks','ephemeral','xcuserdata','.idea','installers'}
SKIP_FILES={'local.properties','Generated.xcconfig','flutter_export_environment.sh','.flutter-plugins-dependencies','GeneratedPluginRegistrant.java','GeneratedPluginRegistrant.h','GeneratedPluginRegistrant.m','postgres.properties','key.properties','ngrok.yml','ngrok.yaml','bank-keys.json','admin-token.txt','pin-pepper.txt','rotated-demo-passwords.json'}
with zipfile.ZipFile(OUTPUT,'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(ROOT.rglob('*')):
        rel=p.relative_to(ROOT)
        # Do not recursively repackage a previously extracted source bundle.
        if rel.parts[0].lower() in {'offline-karo', 'beyondnet'}:continue
        if p.is_symlink() or not p.is_file() or any(part in EXCLUDED for part in rel.parts):continue
        if p.name in SKIP_FILES or p.suffix in {'.zip','.pyc','.iml','.keystore','.jks','.log','.key','.pem','.p12','.pfx'} or p.name=='.DS_Store':continue
        if p.name.startswith('.env') and not p.name.endswith('.example'):continue
        z.write(p,Path('BeyondNet')/rel)
print(f'Created {OUTPUT.name} ({OUTPUT.stat().st_size:,} bytes)')
