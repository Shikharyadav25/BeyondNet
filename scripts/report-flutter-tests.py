#!/usr/bin/env python3
"""Report known test filenames/counts/categories without exporting raw test data."""
import json
from pathlib import Path
import sys


def main():
    known = {p.name for p in Path('test').glob('*_test.dart')}
    suites, tests, failures = {}, {}, set()
    events = malformed = passed = skipped = errors = 0
    categories = set()
    allowed = ['ProcessException', 'FileSystemException', 'SocketException', 'TimeoutException',
               'No such file or directory', 'Permission denied', 'Failed to load', 'Expected:']
    for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            malformed += 1
            categories.update(c for c in allowed if c in line)
            continue
        if not isinstance(event, dict):
            malformed += 1
            continue
        events += 1
        kind = event.get('type')
        if kind == 'suite':
            suite = event.get('suite', {})
            filename = Path(suite.get('path', '')).name
            suites[suite.get('id')] = filename if filename in known else 'runner'
        elif kind == 'testStart':
            test = event.get('test', {})
            tests[test.get('id')] = suites.get(test.get('suiteID'), 'runner')
        elif kind == 'error':
            errors += 1
            failures.add(tests.get(event.get('testID'), 'runner'))
            categories.update(c for c in allowed if c in str(event.get('error', '')))
        elif kind == 'testDone' and not event.get('hidden'):
            if event.get('skipped'):
                skipped += 1
            elif event.get('result') == 'success':
                passed += 1
            else:
                failures.add(tests.get(event.get('testID'), 'runner'))
    summary = f'Flutter: {passed} passed, {skipped} skipped, {errors} errors; {events} JSON events, {malformed} non-JSON lines. Failing known test files: {", ".join(sorted(failures)) or "none"}. Categories: {", ".join(sorted(categories)) or "none"}.'
    print('::notice::' + summary)


if __name__ == '__main__':
    main()
