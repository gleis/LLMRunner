"""Check the exact pinned public source commit against OSV (fail on errors)."""
import json
import re
import urllib.request
from pathlib import Path

pin = re.search(r"^REV=([a-f0-9]{40})", Path(__file__).with_name("bootstrap-llama.sh").read_text(), re.M).group(1)
request = urllib.request.Request("https://api.osv.dev/v1/query", data=json.dumps({"commit": pin}).encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(request, timeout=30) as response:
    report = json.load(response)
issues = report.get("vulns", [])
for issue in issues:
    print(issue["id"], issue.get("summary", ""))
print(f"llama.cpp {pin}: {len(issues)} known advisories")
raise SystemExit(bool(issues))
