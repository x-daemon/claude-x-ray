#!/usr/bin/env python3
"""S2A Claude X-Ray: Claude Code hook that sends the new lines of the session's transcript to
X-Ray on the user's computers (Mac or Windows), so cloud sessions appear there in near real time.

Install as a hook for UserPromptSubmit, PostToolUse, Stop, SubagentStop and PreCompact
(cloud/setup-environment.sh does this). It needs XRAY_PUSH_URL: one receiver URL, for example
https://<computer>.<tailnet>.ts.net/v1/transcript, or several separated by spaces or commas.
Each receiver's token is added to the request by the cloud environment's network secret for
that host, so it never appears here.
Returns to Claude Code at once and uploads in the background, one process per receiver, so an
offline computer does not hold up the others. While an upload to a receiver is running, later
hooks leave their lines to it instead of queueing behind it, so at most one process per
receiver waits on a computer that is asleep. A failed upload is retried on the next hook,
because only acknowledged bytes advance that receiver's saved offset.
"""
import fcntl, hashlib, json, os, subprocess, sys

URLS = [u for u in os.environ.get("XRAY_PUSH_URL", "").replace(",", " ").split() if u]
STATE = "/tmp/xray-push"
CHUNK = 4 * 1024 * 1024

def main():
    try:
        hook = json.load(sys.stdin)
    except Exception:
        return
    paths = [p for p in (hook.get("transcript_path"), hook.get("agent_transcript_path")) if p]
    if not URLS or not paths:
        return
    if os.fork():  # parent: let Claude Code continue immediately
        return
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    os.makedirs(STATE, exist_ok=True)
    for url in URLS:
        if os.fork() == 0:  # one uploader per receiver
            for path in paths:
                push(url, path, str(hook.get("session_id", "")))
            os._exit(0)

def push(url, path, session):
    if not os.path.isfile(path):
        return
    receiver = hashlib.sha1(url.encode()).hexdigest()[:10]
    key = path.strip("/").replace("/", "_") + "." + receiver
    relative = path.split("/projects/", 1)[-1] if "/projects/" in path else os.path.basename(path)
    while True:
        with open(os.path.join(STATE, key + ".lock"), "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return  # an upload to this receiver is running: it sends these lines too
            seen = upload(url, path, session, relative, os.path.join(STATE, key + ".offset"))
        if seen is None or os.path.getsize(path) <= seen:
            return
        # The file grew after the last look: a hook that fired meanwhile left its lines to us.

def upload(url, path, session, relative, offset_file):
    """Sends complete lines after the saved offset; returns the file size it saw last,
    or None if the receiver did not acknowledge (the next hook retries)."""
    try:
        with open(offset_file) as f:
            offset = int(f.read())
    except Exception:
        offset = 0
    while True:
        size = os.path.getsize(path)
        if size < offset:
            offset = 0  # the file was replaced
        if size <= offset:
            return size
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read(min(size - offset, CHUNK))
            if not data.endswith(b"\n"):
                data += f.readline()  # finish the last line: one line can be longer than a chunk
        end = data.rfind(b"\n") + 1
        if end == 0:
            return size  # only a partial line so far
        result = subprocess.run(
            ["curl", "-sSf", "--connect-timeout", "10", "--max-time", "120", "-X", "POST", url,
             "-H", "Content-Type: application/x-ndjson",
             "-H", "X-Session-Id: " + session,
             "-H", "X-Path: " + relative,
             "--data-binary", "@-"],
            input=data[:end], capture_output=True)
        if result.returncode != 0:
            return None
        offset += end
        with open(offset_file, "w") as f:
            f.write(str(offset))

if __name__ == "__main__":
    main()
