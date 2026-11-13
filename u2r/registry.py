"""ported.json bookkeeping + the localhost sync server the Roblox Studio plugin talks to."""
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 34891


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class Registry:
    def __init__(self):
        self._lock = threading.RLock()
        self.path = None
        self.out_dir = None
        self.entries: dict[str, dict] = {}
        self.catalog: list[tuple[int, str, list[str]]] = []   # (id, name, mini costumes)
        self.on_change = None
        self._server = None

    @staticmethod
    def key(cid: int, costume: str) -> str:
        return f"{cid}_{costume}"

    def load(self, out_dir: str):
        with self._lock:
            self.out_dir = out_dir
            self.path = os.path.join(out_dir, "ported.json")
            self.entries = {}
            if os.path.exists(self.path):
                try:
                    with open(self.path, "r", encoding="utf-8") as f:
                        self.entries = json.load(f)
                except Exception:
                    self.entries = {}

    def _save(self):
        if not self.path:
            return
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.entries, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.path)

    def status_of(self, cid: int) -> str:
        with self._lock:
            es = [e for e in self.entries.values() if e.get("id") == cid]
        if not es:
            return ""
        return "in Studio" if any(e.get("imported") for e in es) else "exported"

    def mark_exported(self, cid, name, costume, glb):
        with self._lock:
            e = self.entries.setdefault(self.key(cid, costume), {"id": cid, "costume": costume})
            e.update(name=name, glb=glb, exportedAt=_now())
            self._save()
        self._changed()

    def mark_imported(self, items) -> int:
        n = 0
        with self._lock:
            names = {c[0]: c[1] for c in self.catalog}
            for cid, costume in items:
                e = self.entries.setdefault(self.key(cid, costume), {"id": cid, "costume": costume, "name": names.get(cid, "")})
                if not e.get("imported"):
                    e["imported"], e["importedAt"] = True, _now()
                    n += 1
            self._save()
        self._changed()
        return n

    def forget(self, cid: int):
        with self._lock:
            for k in [k for k, e in self.entries.items() if e.get("id") == cid]:
                del self.entries[k]
            self._save()
        self._changed()

    def _changed(self):
        if self.on_change:
            try:
                self.on_change()
            except Exception:
                pass

    def status_json(self) -> dict:
        with self._lock:
            ported_ids = {e.get("id") for e in self.entries.values()}
            return {
                "ported": sorted(self.entries.values(), key=lambda e: (e.get("id", 0), e.get("costume", ""))),
                "unported": [{"id": i, "name": n, "costumes": c} for i, n, c in self.catalog if i not in ported_ids],
            }

    # ------------------------------------------------------------------ animations
    def _model_meta(self, model: str):
        model = os.path.basename(model)
        p = os.path.join(self.out_dir or "", model + ".json")
        if not os.path.exists(p):
            return None
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)

    def anims_index(self, model: str) -> dict | None:
        meta = self._model_meta(model)
        if meta is None:
            return None
        return {"model": model, "skeleton": meta.get("skeleton", []), "animations": meta.get("animations", []),
                "exportPose": meta.get("exportPose")}

    def anim(self, model: str, name: str) -> dict | None:
        p = os.path.join(self.out_dir or "", "anims", os.path.basename(model), os.path.basename(name) + ".json")
        if not os.path.exists(p):
            return None
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)

    # ------------------------------------------------------------------ server
    def start_server(self) -> str | None:
        if self._server:
            return None
        reg = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                u = urlparse(self.path)
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                path = u.path.rstrip("/")
                if path == "/uma2roblox/status":
                    return self._send(200, reg.status_json())
                if path == "/uma2roblox/anims":
                    r = reg.anims_index(q.get("model", ""))
                    return self._send(200, r) if r is not None else self._send(404, {"error": "unknown model"})
                if path == "/uma2roblox/anim":
                    r = reg.anim(q.get("model", ""), q.get("name", ""))
                    return self._send(200, r) if r is not None else self._send(404, {"error": "unknown animation"})
                self._send(404, {"error": "not found"})

            def do_POST(self):
                if self.path.rstrip("/") != "/uma2roblox/imported":
                    return self._send(404, {"error": "not found"})
                try:
                    n = int(self.headers.get("Content-Length", "0"))
                    data = json.loads(self.rfile.read(n) or b"{}")
                    items = [(int(m["id"]), str(m.get("costume") or "00")) for m in data.get("models", [])]
                    self._send(200, {"marked": reg.mark_imported(items)})
                except Exception as ex:
                    self._send(400, {"error": str(ex)})

        try:
            self._server = ThreadingHTTPServer(("127.0.0.1", PORT), H)
        except OSError as ex:
            return f"Studio sync server could not start on port {PORT}: {ex}"
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return None

    def stop_server(self):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
