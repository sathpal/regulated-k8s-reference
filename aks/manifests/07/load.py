"""Load generator for the lab-07 drills: one new connection per request (like curl), counts every failure.

Env: TARGET (URL), DURATION seconds (0 = run until stopped), WORKERS threads, INTERVAL seconds between a
worker's requests (0 = as fast as possible), REPORT seconds between progress lines.
Prints a progress line every REPORT seconds and a final summary: total, ok, failed, versions seen.
"""
import collections, http.client, json, os, signal, sys, threading, time, urllib.parse

url = urllib.parse.urlparse(os.environ.get("TARGET", "http://payments-api/version"))
duration = float(os.environ.get("DURATION", "120"))
workers = int(os.environ.get("WORKERS", "2"))
interval = float(os.environ.get("INTERVAL", "0.2"))
report = float(os.environ.get("REPORT", "10"))

counts, lock, stop = collections.Counter(), threading.Lock(), threading.Event()
versions, errors = collections.Counter(), collections.Counter()


def one_request():
    conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=2)
    try:
        conn.request("GET", url.path or "/", headers={"Connection": "close", "X-Caller": "loadgen"})
        r = conn.getresponse()
        body = r.read()
        if r.status != 200:
            return False, f"HTTP {r.status}", None
        try:
            return True, None, json.loads(body).get("version")
        except ValueError:
            return True, None, None
    except Exception as e:  # refused, reset, timeout: all count as failed requests
        return False, type(e).__name__, None
    finally:
        conn.close()


def worker():
    while not stop.is_set():
        ok, err, ver = one_request()
        with lock:
            counts["total"] += 1
            counts["ok" if ok else "failed"] += 1
            if ver:
                versions[ver] += 1
            if err:
                errors[err] += 1
                print(f"{time.strftime('%H:%M:%S')} FAILED {err}", flush=True)
        if interval:
            time.sleep(interval)


def line(prefix):
    with lock:
        v = " ".join(f"v{k[:7]}={n}" for k, n in sorted(versions.items()))  # git SHAs shortened
        e = " ".join(f"{k}={n}" for k, n in sorted(errors.items()))
        print(f"{time.strftime('%H:%M:%S')} {prefix} total={counts['total']} ok={counts['ok']} "
              f"failed={counts['failed']} {v} {e}".rstrip(), flush=True)


signal.signal(signal.SIGTERM, lambda *_: stop.set())
start = time.time()
for _ in range(workers):
    threading.Thread(target=worker, daemon=True).start()
while not stop.is_set() and (duration == 0 or time.time() - start < duration):
    stop.wait(report)
    line("progress")
stop.set()
time.sleep(2.5)  # let in-flight requests finish (timeout is 2 s)
line("SUMMARY")
sys.exit(0)
