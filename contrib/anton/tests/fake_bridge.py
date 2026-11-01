"""Protocol fixture for headless Neovim; no desktop session required."""
import json
import os
import sys

for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ["GHOSTTY_BRIDGE_TRACE"], "a", encoding="utf-8") as trace:
        trace.write(json.dumps(request, ensure_ascii=False) + "\n")
    performed = not (request["operation"] == "move" and request["value"] == "left")
    print(json.dumps({"id": request["id"], "performed": performed}), flush=True)
