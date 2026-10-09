"""Run the software rehearsal without a browser, using a separate persistent bank."""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from bank.app import create_app
from bank.demo import rehearse
app=create_app(Path(__file__).resolve().parents[1]/'data'/'cli-rehearsal')
result=rehearse(app)
for step in result['trace']:print('✓ '+step)
print(json.dumps(result.get('receipt',{}),indent=2))
