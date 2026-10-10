"""Print relevant macOS test crash frames without dumping environment data."""
import json
from pathlib import Path
import time

time.sleep(3)
reports = Path.home() / 'Library/Logs/DiagnosticReports'
for path in sorted(reports.glob('*.ips'), key=lambda p: p.stat().st_mtime, reverse=True)[:8]:
    if not any(name in path.name.lower() for name in ['tas', 'xctest', 'swift']):
        continue
    text = path.read_text()
    decoder = json.JSONDecoder()
    values = []
    while text.strip():
        try:
            value, offset = decoder.raw_decode(text.lstrip())
            values.append(value)
            text = text.lstrip()[offset:]
        except ValueError:
            break
    for value in values:
        if 'threads' not in value:
            continue
        print('Crash report:', path.name)
        print('Exception:', value.get('exception'), 'Termination:', value.get('termination'))
        print('Application information:', value.get('asi'))
        for thread in value['threads']:
            if thread.get('triggered'):
                for frame in thread.get('frames', [])[:35]:
                    print(frame)
