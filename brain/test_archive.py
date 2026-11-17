"""오래된 기록 보관 점검 (실제 sftp 없이): python3 -I test_archive.py"""
import gzip
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import archive as A  # noqa: E402

failed = 0


def check(name, ok, detail=""):
    global failed
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  → {detail}"))
    failed += 0 if ok else 1


tmp = Path(tempfile.mkdtemp(prefix="mgarch-test-"))
try:
    data, wiki = tmp / "data", tmp / "wiki"
    (wiki / "timeline").mkdir(parents=True)
    data.mkdir()
    now = datetime(2026, 11, 18, 15, 0).timestamp()
    day = 86400

    ev = sqlite3.connect(data / "actlog.db")
    ev.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, ts REAL NOT NULL, mono INTEGER NOT NULL, source TEXT NOT NULL,"
               " app TEXT, bundle TEXT, pid INTEGER, window TEXT, url TEXT, payload TEXT NOT NULL, privacy TEXT NOT NULL DEFAULT 'none')")
    for i, (age, src, text) in enumerate([(40, "text", "옛날 입력"), (35, "window", ""), (31.5, "paste", "붙여넣기"), (10, "text", "최근 입력")]):
        ev.execute("INSERT INTO events(ts,mono,source,app,payload) VALUES(?,?,?,?,?)",
                   (now - age * day, i, src, "Notes", json.dumps({"text": text}, ensure_ascii=False)))
    ev.commit()
    br = sqlite3.connect(data / "brain.db")
    br.executescript("""
    CREATE TABLE episodes (id INTEGER PRIMARY KEY, start REAL, end REAL, status TEXT, app TEXT, bundle TEXT, ctx TEXT, title TEXT,
      first_event INTEGER, last_event INTEGER, summary TEXT, summary_hash TEXT, judged_hash TEXT, judged_at REAL);
    CREATE TABLE decisions (episode_id INTEGER, qset TEXT, question TEXT, answer TEXT, confidence REAL, probs TEXT,
      ts REAL, ms INTEGER, final INTEGER, PRIMARY KEY (episode_id, qset, question));
    CREATE TABLE labels (episode_id INTEGER, question TEXT, answer TEXT, ts REAL);
    """)
    br.execute("INSERT INTO episodes(id,start,end,summary) VALUES(1,?,?,?)", (now - 40 * day, now - 40 * day + 60, '{"texts":["옛날"]}'))
    br.execute("INSERT INTO episodes(id,start,end,summary) VALUES(2,?,?,?)", (now - 5 * day, now - 5 * day + 60, '{"texts":["최근"]}'))
    br.execute("INSERT INTO decisions VALUES(1,'v1','project','meowgent',0.9,'{}',?,0,1)", (now,))
    br.execute("INSERT INTO labels VALUES(1,'project','meowgent',?)", (now,))
    br.commit()
    for d in ("2026-10-08", "2026-11-10"):
        (wiki / "timeline" / f"{d}.md").write_text(f"# {d}\n")

    # 설정 해석
    check("보관할 곳: 호스트:경로", A.target({"archiveTo": "samsung:/C:/x/arch/"}) == ("samsung", "/C:/x/arch"))
    check("보관할 곳: 모양이 틀리면 None",
          all(A.target({"archiveTo": v}) is None for v in ("", "samsung", ":/x", "-oProxy:/x", 'a:"b')) and A.target({}) is None)
    check("보관 안 켰으면 지우기 상한 없음", A.limit({}, data) is None)
    check("켰는데 보관한 게 없으면 상한 0", A.limit({"archiveTo": "samsung:/x"}, data) == 0.0)
    check("모양이 틀려도 켠 것으로 보고 막는다", A.limit({"archiveTo": "samsung"}, data) == 0.0)
    end = A.cutoff(now, 30, 180)
    check("보관 범위 끝은 30일 전 자정", datetime.fromtimestamp(end) == datetime(2026, 10, 19))
    check("둘 다 0이면 보관할 것 없음", A.cutoff(now, 0, 0) is None and A.cutoff(now, 0, 7) == datetime(2026, 11, 11).timestamp())

    # 보내기 실패: through 그대로, 오류는 한 번만 적는다
    cfg = {"archiveTo": "samsung:/C:/arch"}
    logs = []
    def broken(*a):
        raise RuntimeError("Connection timed out")
    check("보내기 실패하면 None", A.run(cfg, data, wiki, (30, 180), now=now, log=logs.append, sender=broken) is None)
    A.run(cfg, data, wiki, (30, 180), now=now + 3600, log=logs.append, sender=broken)
    check("실패해도 지우기 상한은 0", A.limit(cfg, data) == 0.0)
    check("같은 오류는 한 번만 적음", len(logs) == 1 and "Connection timed out" in logs[0], logs)
    check("임시 파일 남기지 않음", not list(Path(tempfile.gettempdir()).glob("meowgent-archive-*/*")))

    # 보내기 성공
    sent = {}
    def fake(local, host, path, name):
        sent.update(host=host, path=path, name=name, body=gzip.decompress(Path(local).read_bytes()))
        return A.sha256(local)
    logs.clear()
    n = A.run(cfg, data, wiki, (30, 180), now=now, log=logs.append, sender=fake)
    lines = [json.loads(x) for x in sent["body"].decode().splitlines()]
    kinds = [r["kind"] for r in lines]
    check("보낸 곳", sent["host"] == "samsung" and sent["path"] == "/C:/arch" and sent["name"].endswith("-start-20261019.jsonl.gz"), sent.get("name"))
    check("맨 앞은 meta", lines[0]["kind"] == "meta" and lines[0]["to"] == end and lines[0]["from"] == 0)
    check("30일 넘은 이벤트만 (내용 포함)", [r.get("payload") for r in lines if r["kind"] == "event"]
          == [json.dumps({"text": t}, ensure_ascii=False) for t in ("옛날 입력", "", "붙여넣기")], kinds)
    check("구간·판단·답 같이", kinds.count("episode") == 1 and kinds.count("decision") == 1 and kinds.count("label") == 1
          and next(r for r in lines if r["kind"] == "episode")["summary"] == '{"texts":["옛날"]}')
    check("오래된 타임라인만", [r["date"] for r in lines if r["kind"] == "timeline"] == ["2026-10-08"])
    check("레코드 수", n == len(lines) - 1 == 7, n)
    st = A.load_state(data)
    check("through 올라감", st["through"] == end and A.limit(cfg, data) == end and "last_error" not in st)
    check("보낸 파일 기록", st["files"][-1]["name"] == sent["name"] and len(st["files"][-1]["sha256"]) == 64)

    # 다음 날: 그 사이만 보냄. 같은 날 다시 돌면 할 일 없음
    check("같은 날 다시 돌면 0", A.run(cfg, data, wiki, (30, 180), now=now + 3600, log=logs.append, sender=fake) == 0)
    sent.clear()
    A.run(cfg, data, wiki, (30, 180), now=now + day, log=logs.append, sender=fake)
    lines = [json.loads(x) for x in sent["body"].decode().splitlines()]
    check("다음 날은 그 하루만", sent["name"].endswith("-20261019-20261020.jsonl.gz") and lines[0]["from"] == end
          and [r["kind"] for r in lines[1:]] == [], [r["kind"] for r in lines])

    # 같은 범위는 같은 바이트 (다시 보내도 덮어써질 뿐)
    a, b = tmp / "a.gz", tmp / "b.gz"
    A.export(data, wiki, 0, end, a, now)
    A.export(data, wiki, 0, end, b, now + 50)
    check("같은 범위면 같은 파일", a.read_bytes() == b.read_bytes())

    # sftp 배치: 상위 폴더부터 만들고, 올린 걸 다시 받아 맞춰 본다
    calls = []
    def fake_run(cmd, **kw):
        batch = Path(cmd[cmd.index("-b") + 1]).read_text().splitlines()
        calls.append((cmd, batch))
        put = batch[-2].split('"')
        get = batch[-1].split('"')
        shutil.copy(put[1], get[3])
        class R: returncode = 0; stdout = ""; stderr = ""
        return R
    digest = A.send(a, "samsung", "/C:/Users/me/arch", "x.jsonl.gz", run=fake_run)
    cmd, batch = calls[0]
    check("sftp 는 BatchMode, 호스트는 마지막", cmd[0] == "sftp" and "BatchMode=yes" in cmd and cmd[-1] == "samsung")
    check("상위 폴더부터 -mkdir", [l for l in batch if l.startswith("-mkdir")]
          == ['-mkdir "/C:"', '-mkdir "/C:/Users"', '-mkdir "/C:/Users/me"', '-mkdir "/C:/Users/me/arch"'], batch)
    check("다시 받아 맞으면 sha256", digest == A.sha256(a))
    def bad_run(cmd, **kw):
        batch = Path(cmd[cmd.index("-b") + 1]).read_text().splitlines()
        Path(batch[-1].split('"')[3]).write_bytes(b"broken")
        class R: returncode = 0; stdout = ""; stderr = ""
        return R
    try:
        A.send(a, "samsung", "arch", "x.jsonl.gz", run=bad_run)
        check("다시 받은 게 다르면 실패", False)
    except RuntimeError:
        check("다시 받은 게 다르면 실패", True)
    check("보낸 뒤 배치·사본 지움", sorted(p.name for p in tmp.iterdir() if p.is_file()) == ["a.gz", "b.gz"],
          [p.name for p in tmp.iterdir()])
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\n모두 통과" if not failed else f"\n실패 {failed}건")
sys.exit(1 if failed else 0)
