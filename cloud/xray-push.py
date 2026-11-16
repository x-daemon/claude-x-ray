#!/usr/bin/env python3
"""S2A Claude X-Ray: Claude Code hook that sends the new lines of the session's transcript to
X-Ray on the user's Mac, so cloud sessions appear there in near real time.

Install as a hook for UserPromptSubmit, PostToolUse, Stop, SubagentStop and PreCompact
(cloud/setup-environment.sh does this). It needs XRAY_PUSH_URL, for example
https://<mac>.<tailnet>.ts.net/v1/transcript; the receiver's token is added to the request by
the cloud environment's network secret for that host, so it never appears here.
Returns to Claude Code at once and uploads in the background; a failed upload is retried on
the next hook, because only acknowledged bytes advance the saved offset.
"""
import fcntl, json, os, subprocess, sys

URL = os.environ.get("XRAY_PUSH_URL", "").strip()
STATE = "/tmp/xray-push"
CHUNK = 4 * 1024 * 1024

def main():
    try:
        hook = json.load(sys.stdin)
    except Exception:
        return
    paths = [p for p in (hook.get("transcript_path"), hook.get("agent_transcript_path")) if p]
    if not URL or not paths:
        return
    if os.fork():  # parent: let Claude Code continue immediately
        return
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    os.makedirs(STATE, exist_ok=True)
    for path in paths:
        push(path, str(hook.get("session_id", "")))

def push(path, session):
    if not os.path.isfile(path):
        return
    key = path.strip("/").replace("/", "_")
    relative = path.split("/projects/", 1)[-1] if "/projects/" in path else os.path.basename(path)
    with open(os.path.join(STATE, key + ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        offset_file = os.path.join(STATE, key + ".offset")
        try:
            offset = int(open(offset_file).read())
        except Exception:
            offset = 0
        while True:
            size = os.path.getsize(path)
            if size < offset:
                offset = 0  # the file was replaced
            if size <= offset:
                return
            with open(path, "rb") as f:
                f.seek(offset)
                data = f.read(min(size - offset, CHUNK))
            end = data.rfind(b"\n") + 1
            if end == 0:
                return  # only a partial line so far
            result = subprocess.run(
                ["curl", "-sSf", "--max-time", "60", "-X", "POST", URL,
                 "-H", "Content-Type: application/x-ndjson",
                 "-H", "X-Session-Id: " + session,
                 "-H", "X-Path: " + relative,
                 "--data-binary", "@-"],
                input=data[:end], capture_output=True)
            if result.returncode != 0:
                return
            offset += end
            with open(offset_file, "w") as f:
                f.write(str(offset))

if __name__ == "__main__":
    main()
