#!/usr/bin/env python3
"""Tests for cloud/xray-push.py against small local receivers: uploads never queue up behind a
slow or sleeping computer, a hook that fires during an upload still gets its lines sent, long
and partial lines, several receivers at once. Run: python3 cloud/test_xray_push.py"""
import http.server, importlib.util, json, os, shutil, socket, subprocess, sys, tempfile, threading, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))


class Receiver:
    """X-Ray's receiver in miniature: appends each POST body to the file named by X-Path,
    after an optional delay, and records how many requests ran at once."""

    def __init__(self, delay=0.0):
        self.bodies, self.active, self.max_active, self.lock = {}, 0, 0, threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                with outer.lock:
                    outer.active += 1
                    outer.max_active = max(outer.max_active, outer.active)
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                time.sleep(delay)
                with outer.lock:
                    outer.bodies.setdefault(self.headers["X-Path"], bytearray()).extend(body)
                    outer.active -= 1
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/v1/transcript" % self.server.server_port

    def received(self, relative):
        with self.lock:
            return bytes(self.bodies.get(relative, b""))

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def closed_port_url():
    """A receiver that is down: nothing listens there, so connections are refused."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return "http://127.0.0.1:%d/v1/transcript" % port


class XRayPushTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = tempfile.mkdtemp(prefix="xray-push-test-")
        # A copy under a unique name, so the test can count the uploader processes it started.
        cls.hook_path = os.path.join(cls.base, "xray-push-under-test.py")
        shutil.copy(os.path.join(HERE, "xray-push.py"), cls.hook_path)
        spec = importlib.util.spec_from_file_location("xray_push", cls.hook_path)
        cls.hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.hook)
        os.makedirs(cls.hook.STATE, exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.base, ignore_errors=True)
        prefix = cls.base.strip("/").replace("/", "_")
        for name in os.listdir(cls.hook.STATE):
            if name.startswith(prefix):
                os.remove(os.path.join(cls.hook.STATE, name))

    def setUp(self):
        self.receivers = []

    def tearDown(self):
        self.settle()
        for receiver in self.receivers:
            receiver.close()

    # Helpers

    def receiver(self, delay=0.0):
        receiver = Receiver(delay)
        self.receivers.append(receiver)
        return receiver

    def transcript(self, name):
        path = os.path.join(self.base, "projects", "-home-user-demo", name + ".jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "wb").close()
        return path, "-home-user-demo/" + name + ".jsonl"

    @staticmethod
    def append(path, n, size=40):
        with open(path, "ab") as f:
            f.write((json.dumps({"n": n, "pad": "x" * size}) + "\n").encode())

    @staticmethod
    def contents(path):
        with open(path, "rb") as f:
            return f.read()

    def fire(self, path, urls, separator=" "):
        """Runs the hook the way Claude Code does: hook JSON on stdin, returns at once."""
        env = dict(os.environ, XRAY_PUSH_URL=separator.join(urls))
        hook_input = json.dumps({"session_id": "test", "transcript_path": path}).encode()
        subprocess.run([sys.executable, self.hook_path], input=hook_input, env=env, check=True, timeout=10)

    def uploaders(self):
        out = subprocess.run(["pgrep", "-f", self.hook_path], capture_output=True, text=True).stdout
        return len(out.split())

    def settle(self, timeout=60):
        deadline = time.time() + timeout
        while self.uploaders() and time.time() < deadline:
            time.sleep(0.05)

    # Tests

    def test_hooks_do_not_queue_behind_a_slow_receiver(self):
        slow = self.receiver(delay=1.0)
        path, relative = self.transcript("burst")
        peak, sampling = [0], [True]

        def sample():
            while sampling[0]:
                peak[0] = max(peak[0], self.uploaders())
                time.sleep(0.02)

        sampler = threading.Thread(target=sample, daemon=True)
        sampler.start()
        for n in range(30):  # a hook every 0.1 s; each upload takes 1 s
            self.append(path, n)
            self.fire(path, [slow.url])
            time.sleep(0.1)
        self.settle()
        sampling[0] = False
        sampler.join()
        self.assertEqual(slow.received(relative), self.contents(path), "every line arrives exactly once")
        self.assertEqual(slow.max_active, 1, "one upload to a receiver at a time")
        self.assertLessEqual(peak[0], 5, "no queue of waiting processes (30 hooks fired)")

    def test_a_hook_that_fires_while_the_upload_finishes_gets_its_lines_sent(self):
        # The late hook comes after the running upload looked at the file for the last time and
        # before it released the lock: it finds the lock taken and leaves its lines to that upload.
        fast = self.receiver()
        path, relative = self.transcript("race")
        self.append(path, 0)
        original, injected = self.hook.upload, [False]

        def upload_then_late_hook(*args):
            seen = original(*args)
            if not injected[0]:
                injected[0] = True
                self.append(path, 1)
                self.hook.push(fast.url, path, "test")
            return seen

        self.hook.upload = upload_then_late_hook
        try:
            self.hook.push(fast.url, path, "test")
        finally:
            self.hook.upload = original
        self.assertTrue(injected[0])
        self.assertEqual(fast.received(relative), self.contents(path))

    def test_a_line_longer_than_a_chunk_is_sent_whole(self):
        fast = self.receiver()
        path, relative = self.transcript("long")
        self.append(path, 0)
        self.append(path, 1, size=self.hook.CHUNK + 2 * 1024 * 1024)
        self.append(path, 2)
        self.fire(path, [fast.url])
        self.settle()
        self.assertEqual(fast.received(relative), self.contents(path))

    def test_a_partial_line_waits_until_it_is_complete(self):
        fast = self.receiver()
        path, relative = self.transcript("partial")
        self.append(path, 0)
        first_line = self.contents(path)
        with open(path, "ab") as f:
            f.write(b'{"n": 1, "half": ')
        self.fire(path, [fast.url])
        self.settle()
        self.assertEqual(fast.received(relative), first_line)
        with open(path, "ab") as f:
            f.write(b'"done"}\n')
        self.fire(path, [fast.url])
        self.settle()
        self.assertEqual(fast.received(relative), self.contents(path))

    def test_a_receiver_that_is_down_does_not_hold_up_the_other_and_catches_up_later(self):
        online = self.receiver()
        path, relative = self.transcript("two")
        for n in range(5):
            self.append(path, n)
        self.fire(path, [closed_port_url(), online.url])
        self.settle()
        self.assertEqual(online.received(relative), self.contents(path))
        back = self.receiver()  # the computer that was down, back on a new address
        self.append(path, 5)
        self.fire(path, [back.url, online.url], separator=", ")
        self.settle()
        self.assertEqual(back.received(relative), self.contents(path), "the returning receiver gets all of it")
        self.assertEqual(online.received(relative), self.contents(path), "no line twice on the other")


if __name__ == "__main__":
    unittest.main(verbosity=2)
