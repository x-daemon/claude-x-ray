# S2A Claude X-Ray: push each cloud session's transcript to X-Ray (needs XRAY_PUSH_URL).
cat > /usr/local/bin/xray-push <<'XRAY'
#!/usr/bin/env python3
import fcntl, hashlib, json, os, subprocess, sys, time
URLS = [u for u in os.environ.get("XRAY_PUSH_URL", "").replace(",", " ").split() if u]
STATE = os.environ.get("XRAY_PUSH_STATE", "/tmp/xray-push")
CHUNK = 4 * 1024 * 1024
RETRIES = [float(s) for s in os.environ.get("XRAY_PUSH_RETRIES", "5,15,30,60").split(",") if s]
LINGER = float(os.environ.get("XRAY_PUSH_LINGER", "300"))
POLL = float(os.environ.get("XRAY_PUSH_POLL", "2"))
def main():
    try: hook = json.load(sys.stdin)
    except Exception: return
    paths = [p for p in (hook.get("transcript_path"), hook.get("agent_transcript_path")) if p]
    if not URLS or not paths: return
    if os.fork(): return  # parent: let Claude Code continue immediately
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2): os.dup2(devnull, fd)
    os.makedirs(STATE, exist_ok=True)
    for url in URLS:
        for path in paths:
            if os.fork() == 0:  # one uploader per receiver and transcript
                push(url, path, str(hook.get("session_id", "")))
                os._exit(0)
def push(url, path, session):
    if not os.path.isfile(path): return
    key = os.path.join(STATE, path.strip("/").replace("/", "_") + "." + hashlib.sha1(url.encode()).hexdigest()[:10])
    relative = path.split("/projects/", 1)[-1] if "/projects/" in path else os.path.basename(path)
    while True:
        with open(key + ".lock", "w") as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError: return  # another uploader is watching this transcript for this receiver
            seen = watch(url, path, session, relative, key + ".offset")
        if seen is None or os.path.getsize(path) <= seen: return
def watch(url, path, session, relative, offset_file):
    """Sends new lines as they come until the transcript has been quiet for LINGER seconds.
    Returns the size it saw last, or None when it gives up on the receiver."""
    failures, last, quiet_since = 0, -1, time.time()
    while True:
        seen = upload(url, path, session, relative, offset_file)
        if seen == "gone": return None  # the container's proxy is gone: a fresh hook takes over
        if seen is None:
            if failures == len(RETRIES): return None  # the next hook tries again
            time.sleep(RETRIES[failures])
            failures += 1
            continue
        failures = 0
        if seen != last: last, quiet_since = seen, time.time()
        elif time.time() - quiet_since > LINGER: return seen
        time.sleep(POLL)
def upload(url, path, session, relative, offset_file):
    """Sends complete lines after the saved offset; returns the file size it saw last, None if
    the receiver did not acknowledge, or "gone" if nothing could be reached at all."""
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
            return "gone" if result.returncode == 7 else None
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
