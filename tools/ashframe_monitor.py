#!/usr/bin/env python3
"""Ashframe server monitor.

Reads the metrics snapshot the server writes a few times a second
(`saves/<world>/ashframe_metrics.json`) and shows it live, either as a terminal
dashboard or as a small local web page. Keeps history in memory so you can see
whether a change helped or hurt.

Usage:
    python3 tools/ashframe_monitor.py                 # terminal dashboard
    python3 tools/ashframe_monitor.py --path FILE     # explicit metrics file
    python3 tools/ashframe_monitor.py --log run.csv   # also append to a CSV
    python3 tools/ashframe_monitor.py --web 8080      # serve a web dashboard

No third-party packages required.
"""

import argparse
import glob
import json
import os
import sys
import threading
import time
from collections import deque

# fields: (key, label, unit, decimals)
FIELDS = [
    ("tps", "TPS", "", 1),
    ("tick_work_ms_last", "tick work last", "ms", 2),
    ("tick_work_ms_avg", "tick work avg", "ms", 2),
    ("tick_work_ms_peak", "tick work peak", "ms", 2),
    ("tick_ms_last", "tick period last", "ms", 1),
    ("tick_ms_avg", "tick period avg", "ms", 1),
    ("tick_ms_peak_session", "tick period peak (session)", "ms", 1),
    ("players", "players", "", 0),
    ("thread_queue", "thread queue", "", 0),
    ("chunkgen_tasks_per_s", "chunkgen", "/s", 1),
    ("chunkgen_avg_us", "chunkgen avg", "us", 0),
    ("chunk_requests_per_s", "chunk requests", "/s", 1),
    ("chunks_sent_per_s", "chunks sent", "/s", 1),
    ("chunk_tasks_dropped_per_s", "chunk tasks dropped", "/s", 2),
    ("chunk_bytes_per_s", "chunk bandwidth", "B/s", 0),
    ("net_bytes_per_s", "net out", "B/s", 0),
    ("net_recv_bytes_per_s", "net in", "B/s", 0),
    ("deferred_chunk_requests", "deferred chunks", "", 0),
    ("pending_chunk_work", "pending chunk work", "", 0),
    ("held_discarded", "held discarded (total)", "", 0),
    ("load_rd", "load render distance", "", 0),
    ("players_view_capped", "players capped", "", 0),
    ("observed_speed_max", "speed (max)", "b/s", 0),
    ("position_updates_per_s", "position updates", "/s", 1),
    ("anticheat_notes_per_s", "anticheat notes", "/s", 2),
    ("anticheat_notes_throttled_per_s", "anticheat notes muted", "/s", 2),
    ("anticheat_suspects_per_s", "anticheat suspects", "/s", 2),
    ("errors", "errors", "", 0),
    ("warnings", "warnings", "", 0),
]

SPARK = "▁▂▃▄▅▆▇█"


def human(value, unit):
    if unit == "B/s":
        v = float(value)
        for suffix in ("B/s", "KB/s", "MB/s", "GB/s"):
            if abs(v) < 1024.0 or suffix == "GB/s":
                return f"{v:.1f} {suffix}"
            v /= 1024.0
    return f"{value}"


def sparkline(values):
    if not values:
        return ""
    lo, hi = min(values), max(values)
    span = hi - lo
    out = []
    for v in values:
        idx = 0 if span <= 0 else int((v - lo) / span * (len(SPARK) - 1) + 0.5)
        out.append(SPARK[max(0, min(len(SPARK) - 1, idx))])
    return "".join(out)


def find_metrics_path():
    base = os.path.join(os.path.expanduser("~"), ".cubyz", "saves")
    matches = glob.glob(os.path.join(base, "*", "ashframe_metrics.json"))
    if not matches:
        return None
    return max(matches, key=os.path.getmtime)


class Reader(threading.Thread):
    """Polls the metrics file and keeps a rolling history."""

    def __init__(self, path, log_path=None, maxlen=600):
        super().__init__(daemon=True)
        self.path = path
        self.log_path = log_path
        self.history = deque(maxlen=maxlen)
        self.lock = threading.Lock()
        self.sample = None
        self.latest_wall = None
        self.running = True
        self._log_header_written = os.path.exists(log_path) if log_path else True

    def run(self):
        while self.running:
            try:
                with open(self.path, "r") as f:
                    data = json.loads(f.read())
                data["_wall"] = time.time()
                with self.lock:
                    self.sample = data
                    self.latest_wall = data["_wall"]
                    self.history.append(data)
                if self.log_path:
                    self._append_csv(data)
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                pass
            time.sleep(0.2)

    def _append_csv(self, data):
        try:
            write_header = not self._log_header_written
            with open(self.log_path, "a") as f:
                if write_header:
                    f.write(",".join(["wall"] + [k for k, *_ in FIELDS]) + "\n")
                    self._log_header_written = True
                row = [f"{data['_wall']:.3f}"] + [str(data.get(k, "")) for k, *_ in FIELDS]
                f.write(",".join(row) + "\n")
        except OSError:
            pass

    def snapshot(self):
        with self.lock:
            return self.sample, list(self.history)


def render_terminal(reader, world_name):
    CLEAR = "\033[2J\033[H"
    sample, history = reader.snapshot()
    if sample is None:
        print(CLEAR + f"waiting for metrics at {reader.path} ...", end="", flush=True)
        return
    lines = []
    lines.append(f"Ashframe monitor — {world_name}  (Ctrl-C to quit)")
    lines.append(f"source: {reader.path}    samples: {len(history)}")
    lines.append("")
    lines.append(f"{'metric':<20}{'now':>12}{'min':>12}{'avg':>12}{'max':>12}   {'~2 min':<40}")
    lines.append("-" * 110)
    for key, label, unit, decimals in FIELDS:
        series = [s.get(key) for s in history if key in s]
        series = [float(v) for v in series]
        now = float(sample.get(key, 0))
        lo = min(series) if series else now
        hi = max(series) if series else now
        avg = sum(series) / len(series) if series else now
        now_s = human(round(now, decimals), unit)
        lo_s = human(round(lo, decimals), unit)
        avg_s = human(round(avg, decimals), unit)
        hi_s = human(round(hi, decimals), unit)
        spark = sparkline(series[-80:])
        lines.append(f"{label:<20}{now_s:>12}{lo_s:>12}{avg_s:>12}{hi_s:>12}   {spark}")
    sys.stdout.write(CLEAR + "\n".join(lines) + "\n")
    sys.stdout.flush()


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Ashframe monitor</title>
<style>
  body{background:#14161a;color:#e8e8e8;font:13px/1.4 monospace;margin:16px}
  h1{font-size:16px;margin:0 0 4px}
  .sub{color:#8a8a8a;margin-bottom:12px}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px}
  .card{background:#1c1f26;border:1px solid #2a2e37;border-radius:6px;padding:8px 10px}
  .card .t{color:#9aa0aa}
  .card .v{font-size:20px}
  .card canvas{width:100%;height:44px;display:block;margin-top:6px}
</style></head>
<body>
<h1>Ashframe server monitor</h1>
<div class="sub" id="sub">connecting…</div>
<div class="grid" id="grid"></div>
<script>
const FIELDS = __FIELDS__;
const grid = document.getElementById("grid");
const cards = {};
for (const f of FIELDS) {
  const el = document.createElement("div");
  el.className = "card";
  el.innerHTML = `<div class="t">${f[1]} <span style="color:#5a606a">${f[2]}</span></div>`+
                 `<div class="v">–</div><canvas width="240" height="44"></canvas>`;
  grid.appendChild(el);
  cards[f[0]] = {value: el.querySelector(".v"), canvas: el.querySelector("canvas")};
}
function human(v, unit){
  if(unit==="B/s"){const s=["B/s","KB/s","MB/s","GB/s"];let i=0;while(Math.abs(v)>=1024&&i<s.length-1){v/=1024;i++;}return v.toFixed(1)+" "+s[i];}
  return (Math.round(v*10)/10)+"";
}
function draw(canvas, series){
  const ctx = canvas.getContext("2d");
  const w = canvas.width, h = canvas.height;
  ctx.clearRect(0,0,w,h);
  if(series.length < 2) return;
  let lo = Math.min(...series), hi = Math.max(...series);
  if (hi === lo) hi = lo + 1;
  ctx.beginPath();
  ctx.strokeStyle = "#5ec1ff"; ctx.lineWidth = 1.5;
  series.forEach((v,i)=>{
    const x = i/(series.length-1)*w;
    const y = h - (v-lo)/(hi-lo)*(h-4) - 2;
    if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  });
  ctx.stroke();
}
async function tick(){
  try{
    const r = await fetch("/data");
    const d = await r.json();
    if(d.error){document.getElementById("sub").textContent = d.error; return;}
    document.getElementById("sub").textContent =
      "samples: "+d.count+"  ·  "+new Date().toLocaleTimeString();
    for(const f of FIELDS){
      const key=f[0], unit=f[2];
      const series = d.history.map(s=>s[key]).filter(v=>v!==undefined);
      const now = d.sample[key] ?? 0;
      cards[key].value.textContent = human(now, unit);
      draw(cards[key].canvas, series.slice(-120));
    }
  }catch(e){document.getElementById("sub").textContent = "waiting for server…";}
}
setInterval(tick, 500); tick();
</script>
</body></html>
"""


def serve_web(reader, port, world_name):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    page = PAGE.replace("__FIELDS__", json.dumps([[k, label, unit] for k, label, unit, _ in FIELDS]))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path.startswith("/data"):
                sample, history = reader.snapshot()
                if sample is None:
                    body = json.dumps({"error": "waiting for server metrics…"}).encode()
                else:
                    body = json.dumps({"sample": sample, "history": history, "count": len(history)}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/" or self.path.startswith("/index"):
                body = page.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Ashframe monitor web UI on http://127.0.0.1:{port}/  (source: {reader.path})")
    server.serve_forever()


def main():
    ap = argparse.ArgumentParser(description="Ashframe server performance monitor")
    ap.add_argument("--path", help="path to ashframe_metrics.json")
    ap.add_argument("--log", help="also append every sample to this CSV for comparisons")
    ap.add_argument("--web", type=int, metavar="PORT", help="serve a web dashboard on this port")
    args = ap.parse_args()

    path = args.path or find_metrics_path()
    if not path:
        print("Could not find ashframe_metrics.json. Pass --path, or make sure the server "
              "wrote one (launchConfig.zon: ashframeMetrics = true).", file=sys.stderr)
        return 1
    world_name = os.path.basename(os.path.dirname(path))

    reader = Reader(path, log_path=args.log)
    reader.start()

    if args.web:
        try:
            serve_web(reader, args.web, world_name)
        except KeyboardInterrupt:
            return 0
        return 0

    try:
        while True:
            render_terminal(reader, world_name)
            time.sleep(0.5)
    except KeyboardInterrupt:
        print()
        return 0


if __name__ == "__main__":
    sys.exit(main())
