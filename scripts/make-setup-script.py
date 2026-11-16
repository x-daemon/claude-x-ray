#!/usr/bin/env python3
"""Builds cloud/setup-environment.sh from cloud/xray-push.py.

The setup script runs in every new cloud session container of the environment (before Claude
starts): it installs the hook as /usr/local/bin/xray-push and registers it in ~/.claude/settings.json.
Cloud setup scripts are limited to 100 lines, so comments and the docstring are stripped.
"""
import ast
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
source = (root / "cloud" / "xray-push.py").read_text()
tree = ast.parse(source)
doc = ast.get_docstring(tree, clean=False)
body = source.replace('"""' + doc + '"""\n', "", 1) if doc else source
lines = [line for line in body.splitlines() if line.strip() and not line.strip().startswith("#")]
lines.insert(0, "#!/usr/bin/env python3")

register = '''python3 - <<'PY' || true
import json, os
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    s = json.load(open(p))
except Exception:
    s = {}
hooks = s.setdefault("hooks", {})
for event in ("UserPromptSubmit", "PostToolUse", "Stop", "SubagentStop", "PreCompact", "SessionEnd"):
    groups = hooks.setdefault(event, [])
    if not any("xray-push" in json.dumps(g) for g in groups):
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/xray-push"}]})
json.dump(s, open(p, "w"), indent=2)
PY'''

script = "\n".join([
    "# S2A Claude X-Ray: push each cloud session's transcript to X-Ray (needs XRAY_PUSH_URL).",
    "cat > /usr/local/bin/xray-push <<'XRAY'",
    *lines,
    "XRAY",
    "chmod +x /usr/local/bin/xray-push",
    register,
]) + "\n"
out = root / "cloud" / "setup-environment.sh"
out.write_text(script)
count = len(script.splitlines())
longest = max(len(line.encode()) for line in script.splitlines())
print(f"{out.relative_to(root)}: {count} lines, longest {longest} bytes")
assert count <= 100 and longest <= 200, "cloud setup scripts allow 100 lines of 200 bytes"
