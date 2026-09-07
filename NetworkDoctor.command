#!/bin/bash
# Network Doctor 2 — standard-library Python, localhost dashboard, temporary venv.
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Network Doctor requires macOS."
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required. No packages or Python installations were attempted."
  exit 1
fi
ND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/network-doctor-v2.XXXXXX")"
ND_PID=""
cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "$ND_PID" ]; then
    kill -TERM "$ND_PID" 2>/dev/null || true
    wait "$ND_PID" 2>/dev/null || true
  fi
  rm -rf -- "$ND_TMP"
  echo "Temporary environment removed. You can close this terminal."
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
printf 'Preparing isolated workspace: %s\n' "$ND_TMP"
python3 -m venv --without-pip "$ND_TMP/env"
cat > "$ND_TMP/app.py" <<'NETWORK_DOCTOR_PYTHON'
#!/usr/bin/env python3
"""Local-only macOS diagnostics. Python standard library; no third-party packages."""
import concurrent.futures
import copy
import hmac
import ipaddress
import json
import math
import os
import platform
import re
import secrets
import selectors
import signal
import subprocess
import threading
import time
import traceback
from collections import deque
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STOP = threading.Event()
CANCEL = threading.Event()
LOCK = threading.RLock()
PLOCK = threading.Lock()
PROCS = set()
TOKEN = secrets.token_urlsafe(32)
NONCE = secrets.token_urlsafe(18)
LOGS = deque(maxlen=400)
HISTORY = deque(maxlen=120)
SEQ = 0
STATE = dict(busy=False, task=None, started=None, monitor=True,
             status="Starting first scan…", updated=None, metrics={},
             findings=[], details={}, quality=None, quality_error=None,
             interface="Detecting…", gateway="—", sample_count=0)

def log(level, stage, message):
    global SEQ
    message = str(message).strip()[:1800]
    if not message:
        return
    with LOCK:
        SEQ += 1
        entry = dict(id=SEQ, time=time.strftime("%H:%M:%S"),
                     level=level, stage=stage, message=message)
        LOGS.append(entry)
    print(f'[{entry["time"]}] {level.upper():5} {stage}: {message}', flush=True)

def kill_process(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

def run(stage, args, timeout=12, stream=False, expected=(0,)):
    """Read output incrementally, enforce deadline, and support cancellation."""
    log("info", stage, "Starting " + " ".join(args))
    with PLOCK:
        if STOP.is_set() or CANCEL.is_set():
            return 130, "Cancelled"
        try:
            p = subprocess.Popen(args, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True,
                env={**os.environ, "LC_ALL": "C"})
        except OSError as e:
            log("warn", stage, str(e))
            return 127, str(e)
        PROCS.add(p)
    sel = selectors.DefaultSelector()
    sel.register(p.stdout, selectors.EVENT_READ)
    output, pending = bytearray(), b""
    start, heartbeat = time.monotonic(), time.monotonic()
    forced = None
    try:
        while sel.get_map():
            if STOP.is_set() or CANCEL.is_set():
                forced = 130
            elif time.monotonic() - start > timeout:
                forced = 124
            if forced is not None:
                kill_process(p)
                break
            for key, _ in sel.select(.2):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    sel.unregister(key.fileobj)
                    continue
                if len(output) < 262144:
                    output.extend(chunk[:262144-len(output)])
                if stream:
                    pending += chunk
                    lines = re.split(br"[\r\n]", pending)
                    pending = lines.pop()[-8192:]
                    for line in lines:
                        if line.strip():
                            log("info", stage, line.decode("utf-8", "replace"))
            if time.monotonic() - heartbeat >= 5:
                log("info", stage, f"Still running · {int(time.monotonic()-start)}s elapsed")
                heartbeat = time.monotonic()
        # A child can close stdout and keep running; retain the same deadline.
        while forced is None and p.poll() is None:
            if STOP.is_set() or CANCEL.is_set():
                forced = 130
            elif time.monotonic()-start > timeout:
                forced = 124
            else:
                STOP.wait(.1)
        if forced is not None:
            kill_process(p)
        p.wait(timeout=3)
        code = forced if forced is not None else p.returncode
        text = output.decode("utf-8", "replace").strip()
        if stream and pending.strip():
            log("info", stage, pending.decode("utf-8", "replace"))
        if code in (124, 130):
            text += "\n" + ("Timed out" if code == 124 else "Cancelled")
        level = "ok" if code in expected else "warn"
        log(level, stage, f"Finished · exit {code} · {time.monotonic()-start:.1f}s")
        if code not in expected and not stream:
            log("warn", stage, text[-1200:])
        return code, text
    finally:
        sel.close()
        if p.poll() is None:
            kill_process(p)
            p.wait(timeout=3)
        p.stdout.close()
        with PLOCK:
            PROCS.discard(p)

def field(text, name):
    match = re.search(r"^\s*" + re.escape(name) + r":\s*(.+)$", text, re.M)
    return match.group(1).strip() if match else ""

def parse_ping(code, text):
    if code not in (0, 2):
        return dict(avg=None, loss=None, jitter=None, raw=text)
    loss = re.search(r"([\d.]+)% packet loss", text)
    stats = re.search(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", text)
    return dict(avg=float(stats[2]) if stats else None,
                loss=float(loss[1]) if loss else None,
                jitter=float(stats[4]) if stats else None, raw=text)

def probe(label, host):
    try:
        ipaddress.IPv4Address(host)
    except (ValueError, TypeError):
        log("warn", label, "No usable IPv4 gateway; this probe is unavailable.")
        return dict(avg=None, loss=None, jitter=None, raw="No IPv4 target")
    code, text = run(label, ["/sbin/ping", "-n", "-c", "5", "-i", "0.3",
                            "-W", "1000", host], 10, stream=True, expected=(0, 2))
    result = parse_ping(code, text)
    log("ok" if result["loss"] == 0 else "warn", label,
        f'Mean {result["avg"]} ms · loss {result["loss"]}% (5 probes)')
    return result

def check_dns():
    results = []
    for host in ("www.apple.com", "example.com"):
        start = time.monotonic()
        code, text = run("DNS", ["/usr/bin/dscacheutil", "-q", "host", "-a", "name", host], 8)
        ok = code == 0 and bool(re.search(r"(?:ip|ipv6)_address:", text))
        ms = round((time.monotonic()-start)*1000, 1)
        results.append(dict(host=host, ok=ok, ms=ms, raw=text))
        log("ok" if ok else "warn", "DNS", f'{host} · {ms} ms · {"resolved" if ok else "not resolved"}')
    return results

def check_web():
    results = []
    for url in ("https://www.apple.com/", "https://example.com/"):
        code, text = run("HTTPS", ["/usr/bin/curl", "-q", "-L", "-sS", "-o", "/dev/null",
            "--connect-timeout", "4", "--max-time", "8", "-w",
            "\nND_METRICS %{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}", url], 10)
        match = re.search(r"ND_METRICS (\d{3}) (.*)", text)
        status = int(match[1]) if match else None
        ok = code == 0 and status is not None and 200 <= status < 400
        results.append(dict(url=url, ok=ok, code=status, raw=text))
        log("ok" if ok else "warn", "HTTPS", f'{url} · HTTP {status} · {"reachable" if ok else "check failed"}')
    return results

def findings_for(router, remotes, dns, web, iface, ipv4):
    findings = []
    def add(level, title, body, action=None):
        findings.append(dict(level=level, title=title, body=body, action=action))
    if ipv4.startswith("169.254."):
        add("warn", "Self-assigned IPv4 address", "The interface has a 169.254.x.x address. DHCP may not be answering. Check the cable/Wi-Fi, then renew the lease in Network → Details → TCP/IP. IPv6 may still work.", "settings")
    tunnel = iface.startswith(("utun", "ppp", "ipsec"))
    if tunnel:
        add("info", "Tests are using a tunnel", "The default IPv4 route is a VPN/tunnel. The gateway gauge does not isolate your physical router. Compare with the VPN disconnected if appropriate.", "settings")
    if router["avg"] is not None and (router["avg"] > 20 or (router["loss"] or 0) > 0):
        add("warn", "Local-path degradation is possible", "Gateway latency exceeded 20 ms or some probes were lost. Repeat the scan; compare Ethernet and Wi-Fi. Router ICMP handling, interference, traffic, or a tunnel can explain this. This is a troubleshooting threshold, not proof of a faulty router.", "wireless")
    elif router["avg"] is None:
        add("info", "Gateway measurement is inconclusive", "No usable IPv4 ping result. The gateway can filter ping, or the connection may be IPv6-only. A missing reply is not proof of disconnection.", "settings")
    remote_bad = all(r["avg"] is not None and (r["avg"] > 150 or (r["loss"] or 0) > 0) for r in remotes)
    local_good = router["avg"] is not None and router["avg"] <= 20 and router["loss"] == 0
    if remote_bad and local_good and not tunnel:
        add("warn", "Investigate the upstream path", "Both public targets show loss or latency above 150 ms while the local gateway looks better. ISP/transit congestion or routing are possibilities. Geographic distance also affects latency. Repeat and compare with a wired connection.", "trace")
    elif any(r["avg"] is None or (r["loss"] or 0) > 0 for r in remotes):
        add("info", "Internet ping needs context", "One or more public targets did not answer every probe. ICMP can be filtered or deprioritized; compare the HTTPS checks before concluding that application traffic is being lost.", "trace")
    if not all(d["ok"] for d in dns):
        add("warn", "A system DNS lookup failed", "The macOS resolver could not resolve at least one test hostname. An unreachable resolver, connection problem, or VPN DNS policy can cause this. Clearing DNS helps stale cache entries; it does not repair an unreachable DNS server.", "flush")
    elif any(d["ms"] > 500 for d in dns):
        add("warn", "Name resolution was slow", "A lookup took over 500 ms including command startup. Cached answers may be much faster. Repeat to see whether delays persist before changing DNS settings.", "flush")
    if not all(w["ok"] for w in web):
        add("warn", "An HTTPS check failed", "See the live log and evidence for the exact error. DNS, TLS, proxy behavior, a sign-in portal, filtering, or the remote site can cause this. Command-line proxy behavior may differ from Safari.", "settings")
    if not any(f["level"] == "warn" for f in findings):
        add("ok", "No confirmed fault in the quick checks", "This short sample does not prove every service is healthy. Run the optional load test during the slowdown to assess bandwidth and responsiveness.", "quality")
    return findings

def scan():
    code, route = run("Route", ["/sbin/route", "-n", "get", "default"], 4)
    iface, gateway = field(route, "interface"), field(route, "gateway")
    ipv4 = ""
    if re.fullmatch(r"[A-Za-z0-9]{1,16}", iface or ""):
        _, ipv4 = run("Address", ["/usr/sbin/ipconfig", "getifaddr", iface], 3)
        if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ipv4):
            ipv4 = ""
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        jobs = [pool.submit(probe, "Gateway", gateway),
                pool.submit(probe, "Cloudflare", "1.1.1.1"),
                pool.submit(probe, "Google", "8.8.8.8"),
                pool.submit(check_dns), pool.submit(check_web)]
        router, cf, google, dns, web = [j.result() for j in jobs]
    if CANCEL.is_set() or STOP.is_set():
        return
    metrics = dict(router=router["avg"], internet=cf["avg"], google=google["avg"],
                   loss=cf["loss"], dns=max(d["ms"] for d in dns) if all(d["ok"] for d in dns) else None)
    findings = findings_for(router, [cf, google], dns, web, iface, ipv4)
    details = {"IPv4 route": route, "Interface IPv4": ipv4 or "Unavailable",
               "Gateway ping": router["raw"], "Cloudflare ping": cf["raw"], "Google ping": google["raw"]}
    details.update({"DNS · " + d["host"]: d["raw"] for d in dns})
    details.update({"HTTPS · " + w["url"] + " (HTTP, DNS, TCP, TLS, first byte, total seconds)": w["raw"] for w in web})
    with LOCK:
        changed = STATE["interface"] != (iface or "Unavailable") or STATE["gateway"] != (gateway or "Unavailable")
        if changed and HISTORY:
            HISTORY.append(dict(t=time.time(), router=None, internet=None, google=None, loss=None, dns=None))
            log("info", "Route", "Route changed; inserted a gap in the graphs.")
        HISTORY.append(dict(t=time.time(), **metrics))
        STATE.update(metrics=metrics, findings=findings, interface=iface or "Unavailable",
                     gateway=gateway or "Unavailable", updated=time.time(), details=details,
                     sample_count=STATE["sample_count"]+1)
    for f in findings:
        log(f["level"], "Assessment", f["title"])

def parse_quality(text):
    start, end = text.find("{"), text.rfind("}")
    data = json.loads(text[start:end+1])
    if not isinstance(data, dict) or data.get("error_code") not in (None, 0):
        raise ValueError("Apple's test reported an error: " + str(data))
    def number(key, scale=1):
        n = data.get(key)
        return round(n/scale, 2) if isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and n >= 0 else None
    result = dict(download=number("dl_throughput", 1e6), upload=number("ul_throughput", 1e6),
                  rpm=number("responsiveness"), idle=number("base_rtt"), time=time.time())
    if all(result[k] is None for k in ("download", "upload", "rpm")):
        raise ValueError("No recognized capacity or responsiveness fields. See raw evidence.")
    return result

def quality():
    with LOCK:
        STATE.update(quality_error=None)
    code, text = run("Load test", ["/usr/bin/networkQuality", "-c"], 150)
    with LOCK:
        STATE["details"]["Apple networkQuality · raw output"] = text
    if code != 0:
        raise RuntimeError("Load test " + ("cancelled" if code == 130 else f"failed (exit {code}). See live log."))
    result = parse_quality(text)
    with LOCK:
        STATE["quality"] = result
    log("ok", "Load test", f'Download {result["download"]} Mbps · upload {result["upload"]} Mbps · responsiveness {result["rpm"]} RPM')

def diagnostics():
    for label, args in [
        ("Network reachability", ["/usr/sbin/scutil", "--nwi"]),
        ("DNS configuration", ["/usr/sbin/scutil", "--dns"]),
        ("Proxy configuration", ["/usr/sbin/scutil", "--proxy"]),
        ("VPN services", ["/usr/sbin/scutil", "--nc", "list"]),
        ("Hardware ports", ["/usr/sbin/networksetup", "-listallhardwareports"]),
    ]:
        if CANCEL.is_set() or STOP.is_set():
            return
        _, text = run(label, args, 8, stream=True)
        with LOCK:
            STATE["details"][label] = text

def task(action):
    error = None
    try:
        if action == "scan":
            scan()
        elif action == "quality":
            quality()
        elif action == "details":
            diagnostics()
        elif action == "trace":
            log("info", "Traceroute", "Missing hops often mean filtered probes, not a broken router. Maximum 16 hops / 45s.")
            _, text = run("Traceroute", ["/usr/sbin/traceroute", "-n", "-m", "16", "-q", "1", "-w", "1", "1.1.1.1"], 45, stream=True)
            with LOCK:
                STATE["details"]["Traceroute to 1.1.1.1"] = text
        elif action == "flush":
            log("info", "Repair", "macOS will request administrator approval; no password is handled by this dashboard.")
            code, text = run("DNS repair", ["/usr/bin/osascript", "-e",
                'do shell script "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder" with administrator privileges'], 90)
            if code:
                raise RuntimeError("DNS repair cancelled or failed. " + text)
            log("ok", "Repair", "DNS cache cleared. Running a verification scan.")
            scan()
        else:
            commands = {
                "settings": ["/usr/bin/open", "x-apple.systempreferences:com.apple.preference.network"],
                "activity": ["/usr/bin/open", "-a", "Activity Monitor"],
                "wireless": ["/usr/bin/open", "-a", "Wireless Diagnostics"],
            }
            code, text = run("Open macOS tool", commands[action], 8)
            if code:
                raise RuntimeError(text)
            log("info", "Next step", {
                "settings": "For DHCP: your connection → Details → TCP/IP → Renew DHCP Lease. Preserve deliberate static addressing.",
                "activity": "Select Network. Sent/Rcvd Bytes are cumulative; compare changes over time to identify active transfers.",
                "wireless": "Follow Wireless Diagnostics for Wi-Fi-specific evidence. macOS controls access to radio information.",
            }[action])
    except Exception as e:
        error = str(e)
        log("error", action, error)
        if action == "quality":
            with LOCK:
                STATE["quality_error"] = error
    finally:
        cancelled = CANCEL.is_set() or STOP.is_set()
        with LOCK:
            STATE.update(busy=False, task=None, started=None,
                         status="Cancelled" if cancelled else error or "Ready · " + action + " finished")
        log("info", "Task", "Cancelled" if cancelled else "Task finished: " + action)

def start_task(action):
    with LOCK:
        if STATE["busy"] or STOP.is_set():
            return False
        CANCEL.clear()
        STATE.update(busy=True, task=action, started=time.time(), status="Running " + action)
    threading.Thread(target=task, args=(action,), daemon=True).start()
    return True

def monitor():
    due = 0
    while not STOP.wait(.5):
        with LOCK:
            ready = STATE["monitor"] and not STATE["busy"]
        if ready and time.monotonic() >= due:
            if start_task("scan"):
                due = time.monotonic() + 15
        elif not ready:
            due = max(due, time.monotonic() + 3)

class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *args):
        pass

    def send(self, code, obj, cookie=None, html=False):
        body = (obj if html else json.dumps(obj, allow_nan=False)).encode()
        try:
            self.send_response(code)
            for key, value in {
                "Content-Type": ("text/html" if html else "application/json")+"; charset=utf-8",
                "Content-Length": str(len(body)), "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
                "Referrer-Policy": "no-referrer",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-"+NONCE+"'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
            }.items():
                self.send_header(key, value)
            if cookie:
                self.send_header("Set-Cookie", cookie)
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def valid_host(self):
        return self.headers.get("Host") == self.server.address

    def authorized(self):
        try:
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            cookie = cookies.get(self.server.cookie_name)
            return cookie is not None and hmac.compare_digest(cookie.value, TOKEN)
        except Exception:
            return False

    def do_GET(self):
        if not self.valid_host():
            return self.send(403, dict(error="Unexpected Host. Use the exact dashboard URL printed in Terminal."))
        if self.path == "/":
            return self.send(200, self.server.html, html=True)
        if self.path == "/health":
            return self.send(200, dict(ok=True, version=2))
        if not self.authorized():
            return self.send(401, dict(error="Session missing or expired. Open the full URL printed in Terminal to reconnect."))
        if self.path == "/state":
            with LOCK:
                state = copy.deepcopy(STATE)
                state.update(logs=list(LOGS), history=list(HISTORY), server_time=time.time())
            return self.send(200, state)
        self.send(404, dict(error="No such endpoint"))

    def do_POST(self):
        if not self.valid_host() or self.headers.get("Origin") != "http://" + self.server.address:
            return self.send(403, dict(error="Unexpected request origin. Use the dashboard URL printed in Terminal."))
        if self.path == "/session":
            if not hmac.compare_digest(self.headers.get("X-Bootstrap", ""), TOKEN):
                return self.send(401, dict(error="Invalid launch link. Open the latest full URL from Terminal."))
            return self.send(200, dict(ok=True), cookie=self.server.cookie_name+"="+TOKEN+"; HttpOnly; SameSite=Strict; Path=/")
        if not self.authorized():
            return self.send(401, dict(error="Session missing or expired. Open the full URL printed in Terminal."))
        if self.path != "/action":
            return self.send(404, dict(error="No such endpoint"))
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if not 0 < n <= 1024:
                raise ValueError("Invalid size")
            obj = json.loads(self.rfile.read(n))
            action = obj.get("action")
            if action not in {"scan", "quality", "details", "trace", "flush", "settings", "activity", "wireless", "monitor", "cancel", "stop"}:
                raise ValueError("Unknown action")
        except Exception:
            return self.send(400, dict(error="Invalid action request"))
        if action == "stop":
            with LOCK:
                STATE["monitor"] = False
            log("info", "Shutdown", "Stopping dashboard and temporary workspace.")
            self.send(200, dict(ok=True), cookie=self.server.cookie_name+"=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/")
            STOP.set()
            return
        if action == "cancel":
            with LOCK:
                STATE["monitor"] = False
                CANCEL.set()
            log("warn", "Task", "Cancellation requested; automatic monitoring paused.")
        elif action == "monitor":
            with LOCK:
                STATE["monitor"] = not STATE["monitor"]
                enabled = STATE["monitor"]
            log("info", "Monitor", "Enabled" if enabled else "Paused; current check may finish.")
        elif not start_task(action):
            return self.send(409, dict(error="A check is already running. Cancel it or wait for completion."))
        self.send(200, dict(ok=True))

def make_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.timeout = .25
    server.address = "127.0.0.1:" + str(server.server_port)
    server.cookie_name = "nd_session_" + str(server.server_port)
    server.html = Path(__file__).with_name("dashboard.html").read_text().replace("__NONCE__", NONCE)
    return server

def main():
    if platform.system() != "Darwin":
        raise SystemExit("This launcher runs on macOS only.")
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: STOP.set())
    server = make_server()
    url = "http://" + server.address + "/#" + TOKEN
    print("\nNETWORK DOCTOR 2\nOpen this complete link to connect or reconnect:\n" + url + "\n\nCtrl+C stops and removes the temporary environment.\n", flush=True)
    log("info", "Server", "Listening on loopback only. No extra packages installed.")
    run("Browser", ["/usr/bin/open", url], 5)
    threading.Thread(target=monitor, daemon=True).start()
    try:
        while not STOP.is_set():
            server.handle_request()
    finally:
        STOP.set()
        CANCEL.set()
        server.server_close()
        with PLOCK:
            remaining = list(PROCS)
        for p in remaining:
            kill_process(p)
        for p in remaining:
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        print("Network Doctor shut down.", flush=True)

if __name__ == "__main__":
    main()

NETWORK_DOCTOR_PYTHON
cat > "$ND_TMP/dashboard.html" <<'NETWORK_DOCTOR_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Network Doctor · Live diagnostics</title>
<style>
:root{color-scheme:light dark;--bg:#f2f4f8;--panel:#ffffffdf;--ink:#182234;--muted:#5e6d82;--line:#dce3ed;--blue:#0866e7;--green:#138350;--amber:#a65e00;--red:#c63743;--track:#e9edf4;--log:#142032;--logtext:#e3edfa}
*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--bg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}button,input,select{font:inherit}button{cursor:pointer}button:disabled{cursor:default;opacity:.45}button:focus-visible,summary:focus-visible,a:focus-visible,select:focus-visible{outline:3px solid #65a8ff;outline-offset:3px}main{max-width:1320px;padding:30px 28px 48px;margin:auto}header{display:flex;align-items:center;justify-content:space-between;gap:20px}h1{margin:2px 0 0;font-size:30px;font-weight:700;letter-spacing:-1px}h2{font-size:18px;margin:0}p{margin:8px 0;color:var(--muted)}.eyebrow{color:var(--blue);font-size:12px;letter-spacing:1.8px;font-weight:750}.connection{display:flex;align-items:center;gap:9px;font-size:14px;font-weight:600}.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}.connection[data-level=ok] .dot{background:var(--green)}.connection[data-level=error] .dot{background:var(--red)}.topright{display:flex;align-items:center;gap:16px}.button{border:1px solid var(--line);border-radius:12px;background:var(--panel);color:var(--ink);padding:10px 15px;font-size:14px;font-weight:600;white-space:normal}.button:hover:not(:disabled){filter:brightness(.96)}.primary{background:var(--blue);color:#fff;border-color:var(--blue)}.quiet{background:transparent}.toolbar{display:flex;gap:8px;flex-wrap:wrap;margin:22px 0 16px}.context{display:flex;flex-wrap:wrap;gap:9px 25px;font-size:14px;color:var(--muted);padding:15px 0 20px}.context b{color:var(--ink);font-weight:550}.sectionhead{display:flex;align-items:center;justify-content:space-between;gap:15px;margin-bottom:18px}.sectionhead p{font-size:14px;margin:3px 0 0}.tag{border:1px solid var(--line);padding:5px 10px;border-radius:20px;font-size:12px;color:var(--muted)}.gauges{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:15px}.panel{background:var(--panel);border:1px solid var(--line);border-radius:22px;box-shadow:0 4px 18px #18223404;padding:22px}.gauge{text-align:center;padding:19px 12px 16px}.gauge h2{font-size:14px;color:var(--muted);font-weight:600}.dial{position:relative;max-width:180px;margin:8px auto 0}.dial svg{width:100%;display:block;overflow:visible}.track,.arc{fill:none;stroke-width:9;stroke-linecap:round}.track{stroke:var(--track)}.arc{stroke:var(--blue);transition:stroke-dasharray .4s}.dialvalue{position:absolute;inset:0;display:flex;flex-direction:column;justify-content:center;align-items:center;padding-top:14px}.dialvalue strong{font-size:32px;line-height:1.1;letter-spacing:-1.2px;font-weight:650}.dialvalue span{font-size:13px;color:var(--muted);margin-top:6px}.gaugenote{min-height:38px;font-size:12px;color:var(--muted);margin:0}.charts{display:grid;grid-template-columns:2fr 1fr;gap:16px;margin-top:16px}.legend{display:flex;gap:15px;font-size:12px;color:var(--muted);flex-wrap:wrap}.legend span:before{content:"";display:inline-block;width:14px;height:3px;vertical-align:middle;margin-right:5px;background:var(--blue);border-radius:3px}.legend .router:before{background:var(--green)}.legend .google:before{background:#9665dc}.plot{width:100%;height:215px;display:block}.plot text{font:12px -apple-system,BlinkMacSystemFont,sans-serif;fill:var(--muted)}.plot .grid{stroke:var(--line);stroke-dasharray:3 5}.chartnote{font-size:12px;margin:5px 0 0}.lower{display:grid;grid-template-columns:1.1fr 1fr;gap:16px;margin-top:16px}.finding{padding:16px 0;border-bottom:1px solid var(--line)}.finding:first-child{padding-top:0}.finding:last-child{border-bottom:0;padding-bottom:0}.finding h3{font-size:15px;margin:0}.finding p{font-size:14px;margin:7px 0 12px}.severity{font-size:11px;font-weight:750;letter-spacing:.9px;display:block;margin-bottom:5px}.severity.warn{color:var(--amber)}.severity.ok{color:var(--green)}.severity.info{color:var(--muted)}.qualityvalues{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin:16px 0}.qualityvalues strong{font-size:27px;font-weight:650;letter-spacing:-1px;display:block}.qualityvalues span{font-size:12px;color:var(--muted)}.qualityvalues .unit{font-size:13px;font-weight:450;letter-spacing:0}.small{font-size:14px}.repairrow{display:flex;flex-wrap:wrap;gap:8px;margin-top:15px}.logs{margin-top:16px}.logtools{display:flex;gap:9px;align-items:center;flex-wrap:wrap}.logtools label{font-size:13px;color:var(--muted)}select{color:var(--ink);background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:6px 9px;font-size:13px}.logbody{background:var(--log);color:var(--logtext);border-radius:13px;height:310px;overflow:auto;padding:12px;font:12px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace}.logline{display:grid;grid-template-columns:65px 45px 95px minmax(0,1fr);gap:10px;padding:3px 4px;border-bottom:1px solid #ffffff08}.logline time{color:#a5b4ca}.logline .stage{color:#bad1f1}.logline .message{white-space:pre-wrap;overflow-wrap:anywhere}.logline.warn .level{color:#ffcc7c}.logline.error .level{color:#ff9b9b}.logline.ok .level{color:#80dfb0}.logline.info .level{color:#9bbdeb}.logfoot{display:flex;justify-content:space-between;gap:10px;margin-top:10px;font-size:12px;color:var(--muted)}details{margin-top:16px}summary{cursor:pointer;font-size:15px;font-weight:600}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.6 ui-monospace,Menlo,monospace;max-height:400px;overflow:auto}.notice{padding:12px 16px;border-radius:12px;background:#f9e6d7;color:#733507;margin:14px 0;font-size:14px;white-space:pre-wrap}#notice[hidden]{display:none}footer{font-size:12px;color:var(--muted);margin-top:22px}footer a{color:var(--blue)}.empty{font-size:14px;color:var(--muted);padding:12px 0}#taskstatus{font-variant-numeric:tabular-nums}.stale{color:var(--amber)}
@media(max-width:1000px){.charts,.lower{grid-template-columns:1fr}.gauges{gap:10px}.panel{padding:18px}.dialvalue strong{font-size:27px}.gauge{padding:17px 8px}}
@media(max-width:620px){main{padding:20px 14px}header{align-items:start}.topright{flex-direction:column;align-items:end;gap:8px}h1{font-size:25px}.gauges{grid-template-columns:repeat(2,minmax(0,1fr))}.sectionhead{align-items:start;flex-wrap:wrap}.logline{grid-template-columns:58px 38px minmax(0,1fr);gap:7px}.logline .stage{grid-column:3}.logline .message{grid-column:1/-1}.context{gap:7px 15px}.qualityvalues strong{font-size:23px}.toolbar .button{flex:1}.plot{height:200px}}
@media(prefers-color-scheme:dark){:root{--bg:#111824;--panel:#1b2534;--ink:#e8eef8;--muted:#a7b5c9;--line:#303e51;--blue:#5c9eff;--green:#65d7a3;--amber:#ffc36a;--red:#ff939d;--track:#2e3a4c;--log:#0c1420}.primary{background:#176bdc;color:white}.notice{background:#483222;color:#ffcf9f}}
@media(prefers-reduced-motion:reduce){.arc{transition:none}}
</style>
</head>
<body><main>
<header><div><div class="eyebrow">LOCAL NETWORK DIAGNOSTICS</div><h1>Network Doctor</h1></div><div class="topright"><div class="connection" id="connection"><span class="dot"></span><span id="connectiontext">Connecting…</span></div><button class="button quiet" data-action="stop">Stop &amp; clean up</button></div></header>
<div class="toolbar"><button class="button primary" data-action="scan" data-task>Scan now</button><button class="button" id="monitor" data-action="monitor">Pause monitoring</button><button class="button" data-action="quality" data-task>Run load test</button><button class="button" data-action="trace" data-task>Trace route</button><button class="button" data-action="details" data-task>Inspect configuration</button><button class="button quiet" id="cancel" data-action="cancel" disabled>Cancel check</button></div>
<div id="notice" class="notice" role="alert" hidden></div>
<div class="context"><span>Interface <b id="interface">Detecting…</b></span><span>Gateway <b id="gateway">—</b></span><span id="taskstatus" role="status">Waiting for server</span><span id="updated">No completed scan</span></div>
<div class="sectionhead"><div><h2>Connection at a glance</h2><p>Measured values. Missing measurements stay blank.</p></div><span class="tag" id="samplecount">0 scans</span></div>
<section class="gauges" id="gauges" aria-label="Live network gauges"></section>
<section class="charts"><article class="panel"><div class="sectionhead"><h2>Latency over time</h2><div class="legend"><span class="router">Gateway</span><span>Cloudflare</span><span class="google">Google</span></div></div><svg id="latency" class="plot" viewBox="0 0 650 215" role="img" aria-label="Latency history in milliseconds"></svg><p class="chartnote">Lower is better · Hover a point for its reading · Gaps mean no measurement</p></article><article class="panel"><div class="sectionhead"><h2>ICMP packet loss</h2><span class="tag">Cloudflare · %</span></div><svg id="loss" class="plot" viewBox="0 0 650 215" role="img" aria-label="Packet loss history in percent"></svg><p class="chartnote">Five probes per scan. ICMP loss may differ from application traffic.</p></article></section>
<section class="lower"><article class="panel"><div class="sectionhead"><h2>What needs attention</h2><span class="tag">Evidence first</span></div><div id="findings"><div class="empty">The first scan is running. Watch each step in the live log below.</div></div></article><article class="panel"><div class="sectionhead"><h2>Bandwidth under load</h2><button class="button" data-action="quality" data-task>Test</button></div><p class="small">Optional Apple test. It uploads and downloads substantial data and can affect calls while running.</p><div class="qualityvalues"><div><span>DOWNLOAD</span><strong id="download">—</strong><span>Mbps</span></div><div><span>UPLOAD</span><strong id="upload">—</strong><span>Mbps</span></div><div><span>RESPONSIVENESS</span><strong id="rpm">—</strong><span>RPM · higher is better</span></div></div><p class="small" id="qualitynote">Not measured yet. Results describe the test path, not your plan's guaranteed speed.</p><p class="small">Low responsiveness under load can explain lag during transfers. Compare Wi-Fi with Ethernet to help locate the limit.</p><div class="repairrow"><button class="button" data-action="flush" data-task>Clear DNS cache</button><button class="button" data-action="settings" data-task>Network settings</button><button class="button" data-action="wireless" data-task>Wi-Fi diagnostics</button><button class="button" data-action="activity" data-task>Apps using bandwidth</button></div></article></section>
<section class="panel logs"><div class="sectionhead"><div><h2>Live diagnostic log</h2><p>Starts, replies, errors, timeouts, and cancellations as they happen.</p></div><div class="logtools"><label for="logfilter">Show</label><select id="logfilter"><option value="all">All events</option><option value="issues">Warnings &amp; errors</option></select><label><input type="checkbox" id="follow" checked> Auto-scroll</label></div></div><div class="logbody" id="logbody" tabindex="0" aria-label="Live diagnostic events"></div><div class="logfoot"><span id="logcount">Waiting for events…</span><span>Last 400 events · mirrored in Terminal</span></div></section>
<details class="panel"><summary>Raw technical evidence</summary><pre id="evidence">No completed scan yet.</pre></details>
<footer>Local-only dashboard · No third-party dependencies · Automatic quick checks about every 15 seconds; long checks never overlap.<br>Tests contact Apple, Example.com, Cloudflare, and Google. They cannot prove an ISP fault or directly measure Wi-Fi interference. macOS repair/settings actions can have effects beyond this session. The temporary app is removed at normal exit; saved launchers and browser history remain.</footer>
</main>
<script nonce="__NONCE__">
"use strict";
const $=id=>document.getElementById(id);
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const fmt=n=>finite(n)?(n>=100?Math.round(n).toString():n.toFixed(1)):'—';
const esc=x=>String(x).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const defs=[['router','Gateway latency','ms',50,'Lower is better · scale 0–50 ms',20],['internet','Internet latency','ms',200,'Cloudflare · scale 0–200 ms',150],['loss','ICMP packet loss','%',100,'Cloudflare · five probes',0],['dns','System DNS lookup','ms',1000,'Slower of two lookups · scale 0–1,000 ms',500]];
let stopped=false, latest=null, pollTimer=null, lastLog=-1, lastFindings='', lastEvidence='', noticeKind='';
function notice(text,kind='action'){$('notice').textContent=text;$('notice').hidden=!text;noticeKind=kind;}
function connection(text,level){$('connectiontext').textContent=text;$('connection').dataset.level=level;}
function makeGauges(){
 $('gauges').innerHTML=defs.map(([key,title,unit,max,note])=>`<article class="panel gauge"><h2>${title}</h2><div class="dial"><svg viewBox="0 0 160 150" aria-hidden="true"><path class="track" pathLength="100" d="M 37.57 122.43 A 60 60 0 1 1 122.43 122.43"/><path id="arc-${key}" class="arc" pathLength="100" stroke-dasharray="0 100" d="M 37.57 122.43 A 60 60 0 1 1 122.43 122.43"/></svg><div class="dialvalue"><strong id="value-${key}">—</strong><span>${unit}</span></div></div><p class="gaugenote" id="note-${key}">${note}</p></article>`).join('');
}
function chartMarkup(history,keys,colors,fixedMax){
 const W=650,H=215,L=46,R=12,T=18,B=30,pw=W-L-R,ph=H-T-B;
 const values=history.flatMap(p=>keys.map(k=>p[k])).filter(finite);
 const ymax=fixedMax||Math.max(20,Math.ceil(Math.max(0,...values)/20)*20);
 const end=history.length?history[history.length-1].t:Date.now()/1000;
 const begin=history.length>1?history[0].t:end-15;
 const span=Math.max(1,end-begin);
 const x=t=>L+(t-begin)/span*pw,y=v=>T+ph-Math.min(v,ymax)/ymax*ph;
 let html='';
 for(let i=0;i<5;i++){const value=ymax*i/4,py=y(value);html+=`<line class="grid" x1="${L}" y1="${py}" x2="${W-R}" y2="${py}"/><text x="${L-8}" y="${py+4}" text-anchor="end">${Math.round(value)}</text>`;}
 if(!values.length)return html+`<text x="${W/2}" y="${H/2}" text-anchor="middle">Waiting for measured samples</text>`;
 keys.forEach((key,index)=>{
  let path='',active=false,previousTime=null;
  history.forEach(p=>{if(!finite(p[key])){active=false;return;}if(previousTime!==null&&p.t-previousTime>45)active=false;path+=(active?' L ':' M ')+x(p.t).toFixed(2)+' '+y(p[key]).toFixed(2);active=true;previousTime=p.t;});
  html+=`<path d="${path}" fill="none" stroke="${colors[index]}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>`;
  history.forEach(p=>{if(finite(p[key]))html+=`<circle cx="${x(p.t)}" cy="${y(p[key])}" r="3" fill="${colors[index]}"><title>${esc(new Date(p.t*1000).toLocaleTimeString())} · ${key}: ${fmt(p[key])}${fixedMax?'%':' ms'}</title></circle>`;});
 });
 html+=`<text x="${L}" y="${H-5}">${esc(new Date(begin*1000).toLocaleTimeString())}</text><text x="${W-R}" y="${H-5}" text-anchor="end">${esc(new Date(end*1000).toLocaleTimeString())}</text>`;
 return html;
}
function renderLogs(force=false){
 if(!latest)return;
 const rows=latest.logs||[],id=rows.length?rows[rows.length-1].id:0;
 if(id===lastLog&&!force)return;lastLog=id;
 const box=$('logbody'),atBottom=box.scrollHeight-box.scrollTop-box.clientHeight<45,oldScroll=box.scrollTop;
 const filtered=$('logfilter').value==='issues'?rows.filter(r=>r.level==='warn'||r.level==='error'):rows;
 box.innerHTML=filtered.map(r=>`<div class="logline ${esc(r.level)}"><time>${esc(r.time)}</time><span class="level">${esc(r.level.toUpperCase())}</span><span class="stage">${esc(r.stage)}</span><span class="message">${esc(r.message)}</span></div>`).join('')||'<div>No matching events yet.</div>';
 if($('follow').checked&&atBottom)box.scrollTop=box.scrollHeight;else box.scrollTop=oldScroll;
 $('logcount').textContent=`${filtered.length} displayed · ${rows.length} retained`;
}
function render(s){
 latest=s;
 $('interface').textContent=s.interface;$('gateway').textContent=s.gateway;
 const elapsed=s.busy&&finite(s.started)?` · ${Math.max(0,Math.round(s.server_time-s.started))}s`:'';
 $('taskstatus').textContent=s.status+elapsed;
 const age=finite(s.updated)?Math.max(0,Math.round(s.server_time-s.updated)):null;
 $('updated').textContent=age===null?'No completed scan':`Last scan ${age}s ago`;
 $('updated').className=age!==null&&age>45?'stale':'';
 $('monitor').textContent=s.monitor?'Pause monitoring':'Resume monitoring';
 $('cancel').disabled=!s.busy;
 $('samplecount').textContent=`${s.sample_count} scans`;
 for(const [key,title,unit,max,note,threshold] of defs){
  const n=s.metrics[key],amount=finite(n)?Math.max(0,Math.min(100,n/max*100)):0;
  $('value-'+key).textContent=fmt(n);
  $('arc-'+key).setAttribute('stroke-dasharray',`${amount} 100`);
  $('arc-'+key).style.stroke=finite(n)&&n>threshold?'var(--amber)':'var(--blue)';
  $('note-'+key).textContent=finite(n)?note+(n>max?' · above scale':''):'No usable result yet';
 }
 $('latency').innerHTML=chartMarkup(s.history,['router','internet','google'],['var(--green)','var(--blue)','#9665dc']);
 $('loss').innerHTML=chartMarkup(s.history,['loss'],['var(--blue)'],100);
 const findingJSON=JSON.stringify(s.findings);
 if(findingJSON!==lastFindings&&s.findings.length){
  lastFindings=findingJSON;
  const names={settings:'Open network settings',flush:'Clear DNS cache',wireless:'Open Wi-Fi diagnostics',trace:'Trace route',quality:'Run load test'};
  $('findings').innerHTML=s.findings.map(f=>`<div class="finding"><span class="severity ${esc(f.level)}">${f.level==='warn'?'INVESTIGATE':f.level==='ok'?'QUICK CHECK':'CONTEXT'}</span><h3>${esc(f.title)}</h3><p>${esc(f.body)}</p>${f.action?`<button class="button" data-task data-action="${esc(f.action)}">${names[f.action]}</button>`:''}</div>`).join('');
 }
 document.querySelectorAll('[data-task]').forEach(b=>b.disabled=s.busy);
 const q=s.quality;
 if(q){for(const k of ['download','upload','rpm'])$(k).textContent=fmt(q[k]);
  $('qualitynote').textContent=`Last successful test: ${new Date(q.time*1000).toLocaleTimeString()} · Idle latency: ${fmt(q.idle)} ms. These are test results, not current traffic rates.`;}
 if(s.quality_error)$('qualitynote').textContent='Latest attempt: '+s.quality_error+(q?' Previous successful values remain above.':'');
 const evidence=Object.entries(s.details).map(([k,v])=>k+'\n'+v).join('\n\n');
 if(evidence!==lastEvidence){lastEvidence=evidence;$('evidence').textContent=evidence||'No completed scan yet.';}
 renderLogs();
}
class HTTPError extends Error{constructor(status,message){super(message);this.status=status;}}
async function api(path,options={}){
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),6000);
 try{
  let r;
  try{r=await fetch(path,{...options,credentials:'same-origin',cache:'no-store',signal:controller.signal});}
  catch(e){throw new Error(e.name==='AbortError'?'Local server did not respond within 6 seconds.':'Cannot reach the local server: '+e.message);}
  let data;
  try{data=await r.json();}catch(e){throw new Error(`Server returned invalid JSON (HTTP ${r.status}).`);}
  if(!r.ok)throw new HTTPError(r.status,data.error||`HTTP ${r.status}`);
  return data;
 }finally{clearTimeout(timeout);}
}
async function bootstrap(){
 const token=location.hash.slice(1);
 if(token)await api('/session',{method:'POST',headers:{'X-Bootstrap':token}});
 const s=await api('/state');
 // Clear the fragment only after the browser has successfully used its cookie.
 if(token)history.replaceState(null,'',location.pathname);
 return s;
}
async function poll(){
 if(stopped)return;
 let s;
 try{s=await bootstrap();connection('Connected · live','ok');if(noticeKind==='connection')notice('');}
 catch(e){
  if(stopped)return;
  connection(e.status===401?'Session needs reconnect':'Connection error','error');
  notice((e.status?'HTTP '+e.status+': ':'')+e.message+'\nThe Python process may still be running. Open its complete launch URL, including the # portion.','connection');
  pollTimer=setTimeout(poll,4000);return;
 }
 if(stopped)return;
 try{render(s);if(noticeKind==='render')notice('');}catch(e){notice('Dashboard rendering error: '+e.message+'\nThe server connection is working. Terminal continues logging diagnostics.','render');console.error(e);}
 pollTimer=setTimeout(poll,1000);
}
async function act(action){
 if(stopped)return;
 const confirmations={quality:'Run Apple’s load test? It uploads/downloads substantial data and may affect calls.',flush:'Clear the system DNS cache? macOS will request administrator approval. Your configured DNS servers will not change.',stop:'Stop Network Doctor and remove its temporary environment?'};
 if(confirmations[action]&&!confirm(confirmations[action]))return;
 notice('');
 try{
  await api('/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action})});
  if(action==='stop'){
   stopped=true;clearTimeout(pollTimer);connection('Stopped','info');
   $('taskstatus').textContent='Shutdown requested. Terminal reports when temporary cleanup completes.';
   document.querySelectorAll('button').forEach(b=>b.disabled=true);
  }
 }catch(e){notice((e.status?'HTTP '+e.status+': ':'')+e.message);}
}
document.addEventListener('click',e=>{const b=e.target.closest('button[data-action]');if(b&&!b.disabled)act(b.dataset.action);});
$('logfilter').addEventListener('change',()=>renderLogs(true));
$('follow').addEventListener('change',()=>{if($('follow').checked)$('logbody').scrollTop=$('logbody').scrollHeight;});
window.addEventListener('error',e=>notice('Dashboard JavaScript error: '+e.message));
makeGauges();poll();
</script>
</body></html>

NETWORK_DOCTOR_HTML
PYTHONDONTWRITEBYTECODE=1 "$ND_TMP/env/bin/python" -u "$ND_TMP/app.py" &
ND_PID=$!
wait "$ND_PID" || true
