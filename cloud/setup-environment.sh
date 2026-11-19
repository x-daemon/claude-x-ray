# S2A Claude X-Ray: push each cloud session's transcript to X-Ray (needs XRAY_PUSH_URL).
cat > /usr/local/bin/xray-push <<'XRAY'
#!/usr/bin/env python3
import fcntl, hashlib, json, os, subprocess, sys, time
URLS = [u for u in os.environ.get("XRAY_PUSH_URL", "").replace(",", " ").split() if u]
STATE = os.environ.get("XRAY_PUSH_STATE", "/tmp/xray-push")
CHUNK = 4 * 1024 * 1024
RETRIES = [float(s) for s in os.environ.get("XRAY_PUSH_RETRIES", "5,15,30,60").split(",") if s]
SETTLE = float(os.environ.get("XRAY_PUSH_SETTLE", "2"))
def main():
    try: hook = json.load(sys.stdin)
    except Exception: return
    paths = [p for p in (hook.get("transcript_path"), hook.get("agent_transcript_path")) if p]
    if not URLS or not paths:
        return
    settle = hook.get("hook_event_name") in ("Stop", "SubagentStop", "SessionEnd")
    if os.fork():  # parent: let Claude Code continue immediately
        return
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2): os.dup2(devnull, fd)
    os.makedirs(STATE, exist_ok=True)
    for url in URLS:
        if os.fork() == 0:  # one uploader per receiver
            for path in paths:
                push(url, path, str(hook.get("session_id", "")), settle)
            os._exit(0)
def push(url, path, session, settle):
    if not os.path.isfile(path): return
    key = os.path.join(STATE, path.strip("/").replace("/", "_") + "." + hashlib.sha1(url.encode()).hexdigest()[:10])
    relative = path.split("/projects/", 1)[-1] if "/projects/" in path else os.path.basename(path)
    failures = 0
    while True:
        with open(key + ".lock", "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return  # an upload to this receiver is running: it sends these lines too
            seen = upload(url, path, session, relative, key + ".offset")
            if seen is None:
                if failures == len(RETRIES):
                    return  # the next hook tries again
                time.sleep(RETRIES[failures])  # keeping the lock: later hooks leave their lines to us
                failures += 1
                continue
        if settle:
            settle = False
            time.sleep(SETTLE)
        elif os.path.getsize(path) <= seen:
            return
def upload(url, path, session, relative, offset_file):
    """Sends complete lines after the saved offset; returns the file size it saw last,
    or None if the receiver did not acknowledge."""
    try:
        with open(offset_file) as f: offset = int(f.read())
    except Exception: offset = 0
    while True:
        size = os.path.getsize(path)
        if size < offset: offset = 0  # the file was replaced
        if size <= offset: return size
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read(min(size - offset, CHUNK))
            if not data.endswith(b"\n"):
                data += f.readline()  # finish the last line: one line can be longer than a chunk
        end = data.rfind(b"\n") + 1
        if end == 0: return size  # only a partial line so far
        result = subprocess.run(
            ["curl", "-sSf", "--connect-timeout", "10", "--max-time", str(30 + end // 200_000), "-X", "POST", url,
             "-H", "Content-Type: application/x-ndjson", "-H", "X-Session-Id: " + session, "-H", "X-Path: " + relative,
             "--data-binary", "@-"],
            input=data[:end], capture_output=True)
        if result.returncode != 0:
            log(url, "%d bytes: curl %d %s" % (end, result.returncode, result.stderr.decode(errors="replace").strip()[:200]))
            return None
        offset += end
        with open(offset_file, "w") as f: f.write(str(offset))
def log(url, text):
    path = os.path.join(STATE, "errors.log")
    if os.path.exists(path) and os.path.getsize(path) > 100_000: os.replace(path, path + ".1")
    with open(path, "a") as f:
        f.write("%s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), url.split("//")[-1].split("/")[0], text))
if __name__ == "__main__":
    main()
XRAY
chmod +x /usr/local/bin/xray-push
python3 - <<'PY' || true
import json, os
p = os.path.expanduser("~/.claude/settings.json"); os.makedirs(os.path.dirname(p), exist_ok=True)
try: s = json.load(open(p))
except Exception: s = {}
for event in ("UserPromptSubmit", "PostToolUse", "Stop", "SubagentStop", "PreCompact", "SessionEnd"):
    groups = s.setdefault("hooks", {}).setdefault(event, [])
    if not any("xray-push" in json.dumps(g) for g in groups):
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/xray-push"}]})
json.dump(s, open(p, "w"), indent=2)
PY
