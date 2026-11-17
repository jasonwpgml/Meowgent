"""오래된 활동 기록 보관: 보존 기간이 지나 지워질 기록을 먼저 다른 기기로 보낸다.

config.json 의 archiveTo ("ssh호스트:경로") 가 있을 때만 돈다. 없으면 수집기·brain 은 예전처럼 기간이 지나면 바로 지운다.
있으면 하루 단위로 묶어 gzip JSONL 한 파일을 만들고, sftp 로 올린 뒤 다시 받아 sha256 이 같을 때만
archive.json 의 through 를 올린다. 수집기(Store.purge)와 brain(Brain.purge)은 through 보다 이전 것만 지운다.
보내는 데 실패하면 through 가 그대로라 아무것도 지워지지 않고, 다음 시도 때 같은 범위를 다시 보낸다.

파일 한 줄이 한 레코드다: meta(맨 앞), event(actlog.db events 한 줄), episode·decision·label(brain.db),
timeline(wiki/timeline/YYYY-MM-DD.md 원문).
"""
import gzip
import hashlib
import io
import json
import os
import re
import socket
import sqlite3
import subprocess
import tempfile
import time
from contextlib import closing
from datetime import datetime, timedelta
from pathlib import Path

STATE = "archive.json"
VERSION = 1


def target(cfg):
    """archiveTo 를 (호스트, 경로)로. 비었거나 모양이 틀리면 None"""
    t = cfg.get("archiveTo") if isinstance(cfg, dict) else None
    if not isinstance(t, str) or not t.strip():
        return None
    host, _, path = t.strip().partition(":")
    path = path.rstrip("/")
    if not host or not path or host.startswith("-") or any(c in t for c in "\n\r\""):
        return None
    return host, path


def enabled(cfg):
    """보관을 켰는지. 켰으면 모양이 틀려도 지우기는 막는다 (수집기 Config.purgeLimit 과 같은 기준)"""
    t = cfg.get("archiveTo") if isinstance(cfg, dict) else None
    return isinstance(t, str) and bool(t.strip())


def load_state(data):
    try:
        s = json.loads((Path(data) / STATE).read_text())
    except (OSError, ValueError):
        return {}
    return s if isinstance(s, dict) else {}


def limit(cfg, data):
    """지워도 되는 시각의 상한. 보관을 안 켰으면 None, 켰는데 아직 보관한 게 없으면 0"""
    if not enabled(cfg):
        return None
    t = load_state(data).get("through")
    return float(t) if isinstance(t, (int, float)) and not isinstance(t, bool) else 0.0


def cutoff(now, content, total):
    """이번에 보관할 범위의 끝: 가장 짧은 보존 기간 전날의 자정(로컬). 지울 게 없으면 None"""
    days = [d for d in (content, total) if d > 0]
    if not days:
        return None
    edge = datetime.fromtimestamp(now) - timedelta(days=min(days))
    return datetime(edge.year, edge.month, edge.day).timestamp()


def host_name():
    n = socket.gethostname().split(".")[0]
    return re.sub(r"[^A-Za-z0-9_-]", "", n) or "mac"


def _rows(db, sql, args, kind):
    cur = db.execute(sql, args)
    cols = [c[0] for c in cur.description]
    for r in cur:
        yield {"kind": kind, **dict(zip(cols, r))}


def records(data, wiki, start, end):
    """[start, end) 범위에서 지워질 것들. 이벤트는 ts, 구간은 끝난 시각, 타임라인은 파일 날짜 기준 (지우기와 같은 기준)"""
    data = Path(data)
    ev = data / "actlog.db"
    if ev.exists():
        with closing(sqlite3.connect(f"file:{ev}?mode=ro", uri=True)) as db:
            yield from _rows(db, "SELECT * FROM events WHERE ts >= ? AND ts < ? ORDER BY id", (start, end), "event")
    br = data / "brain.db"
    if br.exists():
        with closing(sqlite3.connect(f"file:{br}?mode=ro", uri=True)) as db:
            yield from _rows(db, "SELECT * FROM episodes WHERE end >= ? AND end < ? ORDER BY id", (start, end), "episode")
            ids = "SELECT id FROM episodes WHERE end >= ? AND end < ?"
            for table, kind in (("decisions", "decision"), ("labels", "label")):
                yield from _rows(db, f"SELECT * FROM {table} WHERE episode_id IN ({ids})", (start, end), kind)
    lo = datetime.fromtimestamp(start).strftime("%Y-%m-%d")
    hi = datetime.fromtimestamp(end).strftime("%Y-%m-%d")
    tl = Path(wiki) / "timeline"
    if tl.is_dir():
        for f in sorted(tl.glob("*.md")):
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", f.stem) and lo <= f.stem < hi:
                yield {"kind": "timeline", "date": f.stem, "text": f.read_text(errors="replace")}


def export(data, wiki, start, end, out, now):
    """gzip JSONL 로 쓴다. 같은 범위면 같은 바이트가 나오게 gzip 시각은 0. 레코드 수를 돌려준다"""
    n = 0
    with open(out, "wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as gz, \
            io.TextIOWrapper(gz, encoding="utf-8") as f:
        f.write(json.dumps({"kind": "meta", "version": VERSION, "app": "Meowgent", "host": host_name(),
                            "from": start, "to": end}, ensure_ascii=False) + "\n")
        for r in records(data, wiki, start, end):
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
            n += 1
    return n


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def send(local, host, path, name, run=subprocess.run):
    """sftp 로 올리고 다시 받아 sha256 을 맞춰 본다. 원격 셸에 기대지 않아 윈도우(OpenSSH)에도 같다. 성공하면 sha256"""
    local = Path(local)
    back = local.with_name(local.name + ".back")
    remote = f"{path}/{name}"
    lines = []
    parts = path.split("/")
    for i in range(1, len(parts) + 1):     # 상위 폴더부터 만든다 (이미 있으면 실패해도 넘어감: 앞의 -)
        p = "/".join(parts[:i])
        if p and p != "/":
            lines.append(f'-mkdir "{p}"')
    lines += [f'put "{local}" "{remote}"', f'get "{remote}" "{back}"']
    batch = local.with_name("sftp-batch")
    batch.write_text("\n".join(lines) + "\n")
    try:
        r = run(["sftp", "-q", "-b", str(batch), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host],
                capture_output=True, text=True, timeout=900)
        if r.returncode != 0:
            raise RuntimeError((r.stderr or r.stdout or f"sftp 종료 코드 {r.returncode}").strip().splitlines()[-1][:300])
        want = sha256(local)
        if not back.exists() or sha256(back) != want:
            raise RuntimeError("올린 파일을 다시 받아 보니 내용이 다르다")
        return want
    finally:
        back.unlink(missing_ok=True)
        batch.unlink(missing_ok=True)


def save_state(data, state):
    p = Path(data) / STATE
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1))
    os.replace(tmp, p)


def run(cfg, data, wiki, days, now=None, log=print, sender=send):
    """보관할 게 있으면 보내고 through 를 올린다. 보낸 레코드 수, 할 일이 없으면 0, 실패하면 None"""
    dest = target(cfg)
    if not dest:
        if enabled(cfg):
            log("보관할 곳(archiveTo) 모양이 '호스트:경로'가 아니라 보관도 지우기도 하지 않음")
        return 0
    now = now or time.time()
    end = cutoff(now, *days)
    state = load_state(data)
    start = state.get("through", 0)
    start = float(start) if isinstance(start, (int, float)) and not isinstance(start, bool) else 0.0
    if end is None or end <= start:
        return 0
    fmt = lambda t: datetime.fromtimestamp(t).strftime("%Y%m%d") if t > 0 else "start"
    name = f"meowgent-{host_name()}-{fmt(start)}-{fmt(end)}.jsonl.gz"
    tmp = Path(tempfile.mkdtemp(prefix="meowgent-archive-"))
    try:
        local = tmp / name
        n = export(data, wiki, start, end, local, now)
        digest = sender(local, dest[0], dest[1], name)
        size = local.stat().st_size
    except Exception as e:  # noqa: BLE001 — 실패하면 through 가 그대로라 지우지 않는다
        msg = f"{type(e).__name__}: {e}"
        if state.get("last_error") != msg:
            log(f"오래된 기록 보관 실패, 지우지 않고 다음에 다시 함: {msg}")
            state["last_error"] = msg
            save_state(data, state)
        return None
    finally:
        for f in tmp.iterdir():
            f.unlink(missing_ok=True)
        tmp.rmdir()
    files = state.get("files") if isinstance(state.get("files"), list) else []
    files.append({"name": name, "sha256": digest, "records": n, "bytes": size, "from": start, "to": end, "at": now})
    state.update({"through": end, "files": files, "to": f"{dest[0]}:{dest[1]}"})
    state.pop("last_error", None)
    save_state(data, state)
    log(f"오래된 기록 {n}건 보관함 → {dest[0]}:{dest[1]}/{name}")
    return n
