#!/usr/bin/env python3
"""A small web page for asking the headless runner to review a pull request now.

Paste one or more pull request URLs; each becomes a request file in
$MOCR_RUN_DIR/requests/ and a pass starts straight away. If a pass is already
running, the lock turns the new one into a no-op and the running pass picks the
request up when it reaches the end of its own work. The page also shows what is
pending, whether a pass is running, and the tail of cron.log.

Standard library only. Usage:

    MOCR_RUN_DIR=$HOME/mocr-run python3 inbox.py

Environment:
    MOCR_RUN_DIR       the runner's directory          (default: $HOME/mocr-run)
    MOCR_INBOX_BIND    address to listen on            (default: 127.0.0.1)
    MOCR_INBOX_PORT    port                            (default: 8765)
    MOCR_INBOX_TOKEN   if set, required for every page (default: unset)

Every other variable (MOCR_CODEX_MODEL, ...) is passed through to the runner,
so give this process the same environment as the cron entry.

With MOCR_INBOX_TOKEN set, every page asks for it once and keeps it in a
secure cookie for 30 days. Without it there is no login at all, so only bind to
localhost then. Put a long random value in a chmod 600 environment file
(`openssl rand -hex 32`) before exposing the page through a tunnel or a proxy.
"""

import fcntl
import hmac
import html
import json
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

RUN_DIR = Path(os.environ.get("MOCR_RUN_DIR", Path.home() / "mocr-run"))
REQ_DIR = RUN_DIR / "requests"
CRON_LOG = RUN_DIR / "cron.log"
LOCK = RUN_DIR / ".lock"
RUNNER = Path(__file__).resolve().parent / "codex-run.sh"
BIND = os.environ.get("MOCR_INBOX_BIND", "127.0.0.1")
PORT = int(os.environ.get("MOCR_INBOX_PORT", "8765"))
TOKEN = os.environ.get("MOCR_INBOX_TOKEN", "")

PR_URL = re.compile(r"https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
LOG_LINE = re.compile(r"^(\S+) (\S+?#\d+): (.*)$")


def pass_running() -> bool:
    """True while a runner holds the lock. Probing it takes the lock for an instant."""
    try:
        with open(LOCK, "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fh, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    except OSError:
        return False


def pending() -> list[str]:
    return [p.read_text().strip() for p in sorted(REQ_DIR.glob("*.url"))]


def recent(limit: int = 40) -> list[dict]:
    """The newest lines of cron.log about a pull request, newest first."""
    try:
        lines = CRON_LOG.read_text(errors="replace").splitlines()[-400:]
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        m = LOG_LINE.match(line)
        if not m:
            continue
        when, ref, text = m.groups()
        repo, _, pr = ref.partition("#")
        review = re.search(r"https://github\.com/\S+#pullrequestreview-\d+", text)
        if "posted" in text:
            kind = "ok"
        elif re.search(r"NOTHING POSTED|POST FAILED|ignored|skipped|failed", text):
            kind = "bad"
        else:
            kind = "info"
        out.append({
            "when": when,
            "repo": repo,
            "pr": pr,
            "text": re.sub(r",? ?(https://\S+|log \S+)", "", text).strip(" ,"),
            "review": review.group(0) if review else None,
            "kind": kind,
        })
        if len(out) >= limit:
            break
    return out


def status() -> dict:
    return {"running": pass_running(), "pending": pending(), "recent": recent()}


def enqueue(text: str) -> tuple[list[str], list[str]]:
    """Writes one request file per distinct PR URL in `text`; returns (queued, rejected)."""
    REQ_DIR.mkdir(parents=True, exist_ok=True)
    queued, seen = [], set()
    for owner, repo, pr in PR_URL.findall(text):
        url = f"https://github.com/{owner}/{repo}/pull/{pr}"
        if url in seen or url in pending():
            continue
        seen.add(url)
        (REQ_DIR / f"{time.time_ns()}.url").write_text(url + "\n")
        queued.append(url)
    rejected = [w for w in text.split() if w.startswith("http") and not PR_URL.match(w)]
    if queued:
        start_pass()
    return queued, rejected


def start_pass() -> None:
    """Starts a requests-only pass, detached. A busy lock makes it exit at once."""
    with open(CRON_LOG, "a") as log:
        subprocess.Popen(
            [str(RUNNER), "--requests-only"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, env=os.environ.copy(),
        )


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>mocr inbox</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1b;--muted:#6b6b66;--line:#e2e2dc;--card:#fff;--accent:#2f5bd3;--ok:#1f7a4d;--bad:#b3261e}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ececea;--muted:#9a9a94;--line:#2c2c2a;--card:#1c1c1b;--accent:#8fa9ff;--ok:#6fcf97;--bad:#ff8a80}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:20px;margin:0 0 4px}
.sub{color:var(--muted);margin:0 0 24px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:16px}
textarea{width:100%;min-height:96px;padding:10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg);font:13px/1.4 ui-monospace,monospace;resize:vertical}
input[type=password]{padding:8px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg)}
.row{display:flex;gap:8px;align-items:center;margin-top:10px;flex-wrap:wrap}
button{background:var(--accent);color:#fff;border:0;border-radius:8px;padding:9px 16px;font-weight:600;cursor:pointer}
.state{display:flex;gap:16px;flex-wrap:wrap;color:var(--muted);font-size:14px}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;background:var(--muted)}
.dot.on{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 25%,transparent)}
h2{font-size:14px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:0 0 8px}
ul{list-style:none;margin:0;padding:0}
li{padding:8px 0;border-top:1px solid var(--line);display:grid;grid-template-columns:auto 1fr;gap:2px 12px}
li:first-child{border-top:0}
.when{color:var(--muted);font:12px ui-monospace,monospace;white-space:nowrap}
.ref a{color:var(--fg);font-weight:600;text-decoration:none}
.text{grid-column:2;color:var(--muted);font-size:14px;overflow-wrap:anywhere}
.ok .text{color:var(--ok)} .bad .text{color:var(--bad)}
.text a{color:var(--accent)}
.flash{margin:0 0 16px;padding:10px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card)}
.empty{color:var(--muted);font-size:14px}
@media (max-width:560px){li{grid-template-columns:1fr}.text{grid-column:1}}
</style></head><body><main>
<h1>mocr inbox</h1>
<p class="sub">Paste pull request URLs to review them now, ahead of the queue and whether or not the bot has seen them.</p>
__FLASH__
<form class="card" method="post" action="/requests">
<textarea name="links" placeholder="https://github.com/owner/repo/pull/123" required></textarea>
<div class="row"><button type="submit">Review now</button></div>
</form>
<div class="card"><div class="state" id="state"></div></div>
<div class="card"><h2>Pending</h2><ul id="pending"></ul></div>
<div class="card"><h2>Recent</h2><ul id="recent"></ul></div>
</main>
<script>
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function refresh(){
  let s; try{ s=await (await fetch('/api/status')).json(); }catch(e){ return; }
  document.getElementById('state').innerHTML=
    `<span><span class="dot ${s.running?'on':''}"></span>${s.running?'A pass is running':'Idle'}</span>`+
    `<span>${s.pending.length} pending</span>`;
  document.getElementById('pending').innerHTML=s.pending.length
    ? s.pending.map(u=>`<li><span class="when">queued</span><span class="ref"><a href="${esc(u)}">${esc(u.replace('https://github.com/',''))}</a></span></li>`).join('')
    : '<li class="empty">Nothing waiting.</li>';
  document.getElementById('recent').innerHTML=s.recent.length
    ? s.recent.map(r=>`<li class="${r.kind}"><span class="when">${esc(r.when.replace('T',' ').slice(5,16))}</span>`+
        `<span class="ref"><a href="https://github.com/${esc(r.repo)}/pull/${esc(r.pr)}">${esc(r.repo)}#${esc(r.pr)}</a></span>`+
        `<span class="text">${esc(r.text)}${r.review?` · <a href="${esc(r.review)}">review</a>`:''}</span></li>`).join('')
    : '<li class="empty">No runs logged yet.</li>';
}
refresh(); setInterval(refresh,5000);
</script></body></html>"""


LOGIN = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>mocr inbox</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f7f7f5;color:#1d1d1b;font:15px system-ui,sans-serif}
@media (prefers-color-scheme:dark){body{background:#141413;color:#ececea}input{background:#1c1c1b;color:#ececea}}
form{display:flex;gap:8px;padding:16px}input{width:min(360px,70vw);padding:9px;border:1px solid #8884;border-radius:8px}
button{background:#2f5bd3;color:#fff;border:0;border-radius:8px;padding:9px 16px;font-weight:600}</style></head>
<body><form method="post" action="/login"><input type="password" name="token" placeholder="access key" autofocus required>
<button>Enter</button></form></body></html>"""

COOKIE = "mocr_inbox"


def authorized(headers) -> bool:
    if not TOKEN:
        return True
    for part in (headers.get("Cookie") or "").split(";"):
        name, _, value = part.strip().partition("=")
        if name == COOKIE and hmac.compare_digest(value, TOKEN):
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: str, ctype: str = "text/html; charset=utf-8") -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _page(self, flash: str = "") -> str:
        flash_html = f'<p class="flash">{flash}</p>' if flash else ""
        return PAGE.replace("__FLASH__", flash_html)

    def _redirect(self, location: str, cookie: str = "") -> None:
        self.send_response(303)
        self.send_header("Location", location)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _form(self) -> dict:
        length = min(int(self.headers.get("Content-Length") or 0), 64 * 1024)
        return parse_qs(self.rfile.read(length).decode(errors="replace"))

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if not authorized(self.headers):
            if path == "/api/status":
                self._send(401, "{}", "application/json")
            else:
                self._send(401, LOGIN)
            return
        if path == "/api/status":
            self._send(200, json.dumps(status()), "application/json")
        elif path == "/":
            flash = parse_qs(urlparse(self.path).query).get("m", [""])[0]
            self._send(200, self._page(html.escape(flash)))
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path == "/login":
            if TOKEN and hmac.compare_digest(self._form().get("token", [""])[0], TOKEN):
                self._redirect("/", f"{COOKIE}={TOKEN}; Max-Age=2592000; Path=/; HttpOnly; Secure; SameSite=Strict")
            else:
                time.sleep(1)  # makes guessing slow; the key is long enough that this is only manners
                self._send(401, LOGIN)
            return
        if path != "/requests":
            self._send(404, "not found", "text/plain")
            return
        if not authorized(self.headers):
            self._send(401, LOGIN)
            return
        form = self._form()
        queued, rejected = enqueue(form.get("links", [""])[0])
        parts = []
        if queued:
            parts.append(f"Queued {len(queued)}: " + ", ".join(u.replace("https://github.com/", "") for u in queued) + ".")
        if rejected:
            parts.append("Not pull request URLs: " + ", ".join(rejected[:5]) + ".")
        if not parts:
            parts.append("Nothing new to queue: no pull request URL, or it is already pending.")
        # Post/redirect/get, so reloading the page does not queue the same links again.
        self._redirect("/?m=" + quote(" ".join(parts)))

    def log_message(self, fmt: str, *args) -> None:
        pass


if __name__ == "__main__":
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    print(f"mocr inbox on http://{BIND}:{PORT} (runs in {RUN_DIR})", flush=True)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
