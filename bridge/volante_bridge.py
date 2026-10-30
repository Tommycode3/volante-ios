#!/usr/bin/env python3
"""
Volante Bridge — exposes the Mac's Claude Code to the in-car app.

Why it exists: quick questions in the car go through the API (fractions of a
cent, an answer in a second and a half). The real work — looking at a repo,
writing a document, sending a Slack message, reading Notion, searching
Gmail — goes through here, i.e. through Claude Code on the Mac, which runs on
the subscription and already has all the MCP integrations connected. Zero API
credits for the expensive part, and zero integrations to rewrite in the app.

Zero dependencies: stdlib only.

    python3 volante_bridge.py            # start on 0.0.0.0:8787
    python3 volante_bridge.py --token    # print the token to paste into the app
"""

import argparse
import json
import os
import secrets
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path.home()
STATE = HOME / ".volante"
TASKS = STATE / "tasks"
TOKEN_FILE = STATE / "bridge-token"
PROJECTS_FILE = STATE / "projects.json"

CLAUDE_BIN = os.environ.get("VOLANTE_CLAUDE_BIN", "claude")
PERMISSION_MODE = os.environ.get("VOLANTE_PERMISSION_MODE", "auto")
JOB_TIMEOUT = int(os.environ.get("VOLANTE_TIMEOUT", "900"))

# We always ask for a final speakable line: in the car the answer has to be
# listened to, not read, and a forty-line document can't be read aloud.
VOICE_SUFFIX = (
    "\n\n---\n"
    "Quando hai finito, chiudi la risposta con una riga che inizia esattamente "
    "con 'VOCE:' seguita da UNA sola frase, in italiano, da leggere ad alta voce "
    "a chi sta guidando. In quella riga niente elenchi, niente markdown, niente "
    "sigle non pronunciabili."
)

_jobs = {}
_lock = threading.Lock()


# ---------------------------------------------------------------- state

def ensure_state():
    STATE.mkdir(exist_ok=True)
    TASKS.mkdir(exist_ok=True)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(24))
        TOKEN_FILE.chmod(0o600)
    if not PROJECTS_FILE.exists():
        PROJECTS_FILE.write_text(json.dumps(discover_projects(), indent=2))


def discover_projects():
    """First-time setup: proposes the repos found. After that the file is curated by hand."""
    found = {}
    for base in (HOME / "Code", HOME / "progetti", HOME / "esp"):
        if not base.is_dir():
            continue
        try:
            entries = sorted(base.iterdir())
        except PermissionError:
            continue
        for p in entries:
            if p.is_dir() and (p / ".git").exists():
                found.setdefault(p.name, str(p))
    found.setdefault("home", str(HOME))
    return found


def projects():
    try:
        return json.loads(PROJECTS_FILE.read_text())
    except Exception:
        return {"home": str(HOME)}


def token():
    return TOKEN_FILE.read_text().strip()


def save_job(job):
    (TASKS / f"{job['id']}.json").write_text(
        json.dumps(job, indent=2, ensure_ascii=False))


def read_context():
    """The memory index of this machine's Claude Code.

    It's the file that already describes what the user works on: projects,
    decisions, preferences. By passing it to the app, the in-car assistant
    knows the same things Claude on the Mac knows, and keeps knowing them even
    when the Mac is off.
    """
    parts = []
    claude_md = HOME / ".claude" / "CLAUDE.md"
    if claude_md.exists():
        parts.append(claude_md.read_text(errors="replace")[:6000])
    projects = HOME / ".claude" / "projects"
    if projects.is_dir():
        for p in sorted(projects.glob("*/memory/MEMORY.md")):
            parts.append(p.read_text(errors="replace")[:20000])
    return "\n\n".join(parts).strip()


def public(job):
    return {k: job.get(k) for k in
            ("id", "status", "prompt", "project", "result", "voice",
             "created", "finished")}


# ---------------------------------------------------------------- execution

def run_job(job_id):
    with _lock:
        job = _jobs[job_id]
        job["status"] = "running"
        job["started"] = time.time()
        save_job(job)

    cmd = [CLAUDE_BIN, "-p", "--output-format", "json",
           "--permission-mode", PERMISSION_MODE,
           job["prompt"] + VOICE_SUFFIX]
    try:
        proc = subprocess.run(cmd, cwd=job["cwd"], capture_output=True,
                              text=True, timeout=JOB_TIMEOUT)
        raw = (proc.stdout or "").strip()
        text = raw
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                text = parsed.get("result") or parsed.get("text") or raw
        except Exception:
            pass
        if proc.returncode != 0 and not text:
            text = (proc.stderr or "").strip()[:2000] or \
                   f"claude exited with code {proc.returncode}"
        status = "done" if proc.returncode == 0 else "error"
    except subprocess.TimeoutExpired:
        text, status = f"Timed out after {JOB_TIMEOUT} seconds.", "error"
    except FileNotFoundError:
        text, status = f"'{CLAUDE_BIN}' not found in the service's PATH.", "error"
    except Exception as e:                                   # noqa: BLE001
        text, status = f"{type(e).__name__}: {e}", "error"

    voice = ""
    for line in reversed(text.splitlines()):
        if line.strip().upper().startswith("VOCE:"):
            voice = line.split(":", 1)[1].strip()
            break
    if not voice:
        flat = " ".join(text.split())
        voice = (flat[:220] + "…") if len(flat) > 220 else (flat or "Fatto.")

    with _lock:
        job.update(status=status, result=text, voice=voice, finished=time.time())
        save_job(job)


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {fmt % args}", flush=True)

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer ") and secrets.compare_digest(header[7:], token()):
            return True
        self._send(401, {"error": "invalid token"})
        return False

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "projects": sorted(projects().keys())})
            return
        if not self._authorized():
            return
        if self.path == "/context":
            self._send(200, {"context": read_context()})
            return
        if self.path.startswith("/task/"):
            jid = self.path.split("/task/", 1)[1]
            with _lock:
                job = _jobs.get(jid)
            if job is None:
                f = TASKS / f"{jid}.json"
                job = json.loads(f.read_text()) if f.exists() else None
            if job is None:
                self._send(404, {"error": "unknown task"})
                return
            self._send(200, public(job))
            return
        if self.path.startswith("/tasks"):
            with _lock:
                items = [public(j) for j in _jobs.values()]
            items.sort(key=lambda j: j["created"], reverse=True)
            self._send(200, {"tasks": items[:30]})
            return
        self._send(404, {"error": "unknown endpoint"})

    def do_POST(self):
        if not self._authorized():
            return
        if self.path != "/task":
            self._send(404, {"error": "unknown endpoint"})
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self._send(400, {"error": "invalid JSON"})
            return

        prompt = (body.get("prompt") or "").strip()
        if not prompt:
            self._send(400, {"error": "empty prompt"})
            return

        known = projects()
        name = (body.get("project") or "").strip()
        cwd = known.get(name)
        if not cwd and name:
            # Fuzzy match: transcription from a moving car gets names wrong.
            low = name.lower().replace(" ", "").replace("-", "")
            for k, v in known.items():
                if low in k.lower().replace("-", ""):
                    name, cwd = k, v
                    break
        if not cwd:
            name, cwd = "home", str(HOME)

        job = {"id": uuid.uuid4().hex[:12], "prompt": prompt, "project": name,
               "cwd": cwd, "status": "queued", "created": time.time(),
               "result": "", "voice": ""}
        with _lock:
            _jobs[job["id"]] = job
            save_job(job)
        threading.Thread(target=run_job, args=(job["id"],), daemon=True).start()
        self._send(200, {"id": job["id"], "project": name})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--token", action="store_true", help="print the token and exit")
    args = ap.parse_args()

    ensure_state()
    if args.token:
        print(token())
        return

    print(f"Volante Bridge on http://{args.host}:{args.port}")
    print(f"Token:    {token()}")
    print(f"Projects: {', '.join(sorted(projects()))}")
    print(f"Claude:   {CLAUDE_BIN} (permission mode: {PERMISSION_MODE})")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
