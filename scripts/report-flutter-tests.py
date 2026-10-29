#!/usr/bin/env python3
"""Summarize Flutter's machine reporter without masking the runner's exit status."""
import json
from pathlib import Path
import sys


def escape(text):
    return str(text).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main():
    names = {}
    passed = failed = skipped = 0
    for line in Path(sys.argv[1]).read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get('type')
        if kind == 'testStart':
            names[event['test']['id']] = event['test']['name']
        elif kind == 'error':
            name = names.get(event.get('testID'), 'Flutter runner')
            message = f"{name}: {event.get('error', 'Unknown failure')}\n{event.get('stackTrace', '')}"
            print('::error::' + escape(message[:6000]))
        elif kind == 'testDone' and not event.get('hidden'):
            if event.get('skipped'):
                skipped += 1
            elif event.get('result') == 'success':
                passed += 1
            else:
                failed += 1
    print(f'Flutter: {passed} passed, {failed} failed, {skipped} skipped')


if __name__ == '__main__':
    main()
