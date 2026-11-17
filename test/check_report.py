#!/usr/bin/env python3
"""Exit 0 only if a mock_api.py report shows a finished session with no protocol errors."""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "mock_report.json"
try:
    r = json.load(open(path))
except Exception as e:  # noqa
    print(f"FAIL: no readable report at {path}: {e}")
    sys.exit(1)
print(json.dumps(r, indent=1))
need = 5 if (r.get("guide") or r.get("custom")) else 100
if r.get("done") and not r.get("errors") and not r.get("action_errors") and r.get("passed", 0) >= need:
    print("PASS")
    sys.exit(0)
print("FAIL")
sys.exit(1)
