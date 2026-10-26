#!/usr/bin/env python3
"""ActLog 기록 보기 (읽기 전용).

  python3 tools/actlog_tail.py            # 최근 40건
  python3 tools/actlog_tail.py -n 100 -s text,search
  python3 tools/actlog_tail.py -f         # 실시간으로 따라가기
  python3 tools/actlog_tail.py --stats    # 오늘 소스별 건수
"""
import argparse, json, os, sqlite3, time
from datetime import datetime

DB = os.path.expanduser("~/Library/Application Support/ActLog/actlog.db")

def fmt(row):
    id_, ts, source, app, window, url, payload, privacy = row
    p = json.loads(payload or "{}")
    t = datetime.fromtimestamp(ts).strftime("%H:%M:%S")
    where = app or ""
    if source == "text":
        body = p.get("text") or f"({p.get('chars', '?')}자, {p.get('text_unavailable') or privacy})"
        ai = f"AI질문:{p['ai']} " if p.get("kind") == "ai_prompt" else ""
        detail = f"[{p.get('reason')}] {ai}{body!r}"
    elif source == "ai_response":
        detail = f"AI답변:{p.get('ai')} ({p.get('chars')}자, {p.get('wait_s')}초) {p.get('text', '')[:100]!r}"
    elif source == "click":
        detail = f"{p.get('role')} {p.get('label', '')!r}"
    elif source == "window":
        detail = window or ""
    elif source == "browser":
        detail = f"{p.get('title', '')}  {url or p.get('reason', '')}"
    elif source == "search":
        detail = f"{p.get('engine')}: {p.get('query')!r}"
    elif source == "activity":
        detail = f"키 {p['keys']} · 클릭 {p['clicks']} · 스크롤 {p['scrolls']} · 마우스 {p['mouse_px']}px"
    elif source == "paste":
        body = repr(p.get("text", "")[:80]) if p.get("text") else p.get("kind", privacy)
        detail = f"→ {p.get('field') or p.get('field_role') or ''} {body}"
    elif source == "clipboard":
        detail = repr(p.get("text", "")[:80]) if p.get("text") else p.get("kind", privacy)
    else:
        detail = json.dumps(p, ensure_ascii=False)
    flag = "" if privacy == "none" else f" <{privacy}>"
    return f"{t} {source:9s} {where[:18]:18s} {detail[:140]}{flag}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=40)
    ap.add_argument("-s", "--source", help="쉼표로 구분 (text,click,search,…)")
    ap.add_argument("-f", "--follow", action="store_true")
    ap.add_argument("--stats", action="store_true")
    a = ap.parse_args()
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    if a.stats:
        start = datetime.now().replace(hour=0, minute=0, second=0).timestamp()
        for src, n in con.execute("SELECT source, count(*) FROM events WHERE ts>=? GROUP BY source ORDER BY 2 DESC", (start,)):
            print(f"{src:10s} {n}")
        size = sum(os.path.getsize(DB + s) for s in ("", "-wal") if os.path.exists(DB + s))
        print(f"\nDB 크기 {size/1e6:.1f} MB")
        return
    where, args = "", []
    if a.source:
        srcs = a.source.split(",")
        where = f"WHERE source IN ({','.join('?' * len(srcs))})"
        args = srcs
    cols = "id, ts, source, app, window, url, payload, privacy"
    rows = con.execute(f"SELECT {cols} FROM events {where} ORDER BY id DESC LIMIT ?", (*args, a.n)).fetchall()
    for r in reversed(rows):
        print(fmt(r))
    last = rows[0][0] if rows else 0
    while a.follow:
        time.sleep(1)
        q = f"SELECT {cols} FROM events WHERE id>? {('AND ' + where[6:]) if where else ''} ORDER BY id"
        for r in con.execute(q, (last, *args)):
            print(fmt(r), flush=True)
            last = r[0]

if __name__ == "__main__":
    main()
