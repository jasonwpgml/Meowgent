"""구간 나누기 점검 (DB·Clef 없이): python3 -I test_brain.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import actlog_brain as B

CFG = {**B.DEFAULT_CONFIG}
failed = 0
def check(name, ok, detail=""):
    global failed
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  → {detail}"))
    failed += 0 if ok else 1

class Feed:
    def __init__(self):
        self.closed = []
        self.s = B.Segmenter(CFG, self.closed.append)
        self.id = 0
    def ev(self, t, source, app, bundle, window=None, url=None, **p):
        self.id += 1
        self.s.feed((self.id, 1000.0 + t, source, app, bundle, window, url, p))

CH, CL = "com.google.Chrome", "com.anthropic.claudefordesktop"

# 1) 잠깐 다른 앱 갔다 오면 한 구간
f = Feed()
f.ev(0, "app", "Chrome", CH, "교안 v57", "file:///Users/me/Documents/work/lectures/01_basic/lecture/v57.html")
f.ev(0, "browser", "Chrome", CH, "교안 v57", "file:///Users/me/Documents/work/lectures/01_basic/lecture/v57.html", title="교안 v57")
f.ev(30, "click", "Chrome", CH, "교안 v57", role="AXButton", label="다음")
f.ev(60, "app", "Claude", CL, "Claude")
f.ev(68, "text", "Claude", CL, "Claude", text="이거 맞아?")
f.ev(70, "app", "Chrome", CH, "교안 v57", "file:///Users/me/Documents/work/lectures/01_basic/lecture/v57.html")
f.ev(200, "click", "Chrome", CH, "교안 v57", role="AXButton", label="다음")
check("잠깐 들른 앱은 흡수", len(f.closed) == 0 and f.s.ep and f.s.ep.brief == [("Claude", 8)], f"closed={len(f.closed)} brief={f.s.ep.brief if f.s.ep else None}")
check("들른 곳의 입력도 보존", any(t[1] == "이거 맞아?" for t in f.s.ep.texts))

# 2) 오래 머물면 새 구간
f.ev(300, "app", "Claude", CL, "Claude")
f.ev(330, "text", "Claude", CL, "Claude", text="설계 다시 보자", kind="ai_prompt", ai="claude")
f.ev(340, "click", "Claude", CL, "Claude", role="AXButton", label="보내기")
check("20초 넘게 머물면 앞 구간 닫힘", len(f.closed) == 1 and f.closed[0].app == "Chrome", [c.app for c in f.closed])
check("새 구간은 Claude", f.s.ep.app == "Claude" and f.s.ep.start == 1300.0)

# 3) 같은 브라우저라도 사이트가 바뀌면 다른 맥락
f2 = Feed()
f2.ev(0, "browser", "Chrome", CH, "GitHub", "https://github.com/a/b", title="GitHub")
f2.ev(5, "app", "Chrome", CH, "GitHub", "https://github.com/a/b")
f2.ev(40, "browser", "Chrome", CH, "YouTube", "https://www.youtube.com/watch?v=1", title="YouTube")
f2.s.tick(1000 + 100)
check("사이트 변경 → 새 구간", len(f2.closed) == 1 and f2.s.ep.ctx == (CH, "youtube.com"), f"{[c.ctx for c in f2.closed]} / {f2.s.ep.ctx}")

# 4) 자리 비움은 구간을 닫고, 돌아와서 입력하면 같은 앱으로 새 구간
f3 = Feed()
f3.ev(0, "app", "Claude", CL, "Claude")
f3.ev(10, "text", "Claude", CL, "Claude", text="hi")
f3.ev(15, "afk", None, None, status="afk")
f3.ev(600, "afk", None, None, status="active")
f3.ev(605, "text", "Claude", CL, "Claude", text="다시 왔어")
check("자리 비움에 닫힘", len(f3.closed) == 1)
check("돌아오면 새 구간", f3.s.ep and f3.s.ep.start == 1605.0 and f3.s.ep.app == "Claude")

# 5) 너무 긴 구간은 나눈다
f4 = Feed()
f4.ev(0, "app", "Claude", CL, "Claude")
for t in range(60, 2000, 60):
    f4.ev(t, "text", "Claude", CL, "Claude", text=f"t{t}")
check("30분 넘으면 나눔", len(f4.closed) == 1 and 1790 <= f4.closed[0].duration <= 1810, [c.duration for c in f4.closed])

# 6) Clef 입력 요약: 숫자는 이름으로
st = f.closed[0].state(previous="13:00-13:20 Claude · agent_chat · actlog")
check("요약에 활동량 이름", st["활동량"] in ("거의 없음 (보기만 함)", "낮음", "보통", "높음"), st)
check("요약에 잠깐 들른 곳", st.get("잠깐 들른 곳") == ["Claude 8초"], st.get("잠깐 들른 곳"))
check("파일 맥락은 폴더", f.closed[0].ctx[1] == "file:/Users/me/Documents/work/lectures/01_basic", f.closed[0].ctx)

# 7) 모르는 긴 구간은 inbox 에 질문으로 (실제 DB·폴더 대신 메모리 DB와 임시 폴더)
import json, sqlite3, tempfile, time
from pathlib import Path
B.INBOX = Path(tempfile.mkdtemp()) / "inbox"
B.LOG = B.INBOX.parent / "brain.log"
b = B.Brain.__new__(B.Brain)
b.cfg, b.projects, b.next_ask = CFG, {"meowgent": "Meowgent 만들기: 수집기"}, 0
b.db = sqlite3.connect(":memory:")
b.db.executescript(B.SCHEMA)
now = time.time()
def episode(eid, minutes, answer, conf):
    b.db.execute("INSERT INTO episodes(id,start,end,status,app,title,summary,summary_hash,judged_hash) VALUES(?,?,?,'closed','Claude','Claude',?,'h','h')",
                 (eid, now - 7200, now - 7200 + minutes * 60, json.dumps({"AI에게 한 질문": [f"질문{eid}"]})))
    b.db.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?)", (eid, B.QSET, "project", answer, conf, "{}", now, 0, 1))
episode(1, 20, "none", 0.2)      # 길고 모름 → 묻는다
episode(2, 5, "none", 0.2)       # 짧다
episode(3, 20, "meowgent", 0.9)  # 안다
episode(4, 20, "other", 0.8)     # 새 작업 → 묻는다
b.ask_unclear(now)
asked = sorted(f.name for f in B.INBOX.glob("*.json"))
check("길고 모르는 구간만 질문", asked == ["brain-ep-1.json", "brain-ep-4.json"], asked)
q = json.loads((B.INBOX / "brain-ep-1.json").read_text())
check("질문 형식", q["kind"] == "ask" and q["level"] == "yellow" and q["choices"][0] == {"id": "meowgent", "label": "Meowgent 만들기"} and "질문1" in q["detail"], q)
(B.INBOX / "done").mkdir()
q.update(answer="meowgent", resolved=now)
(B.INBOX / "done" / "brain-ep-1.json").write_text(json.dumps(q))
(B.INBOX / "brain-ep-1.json").unlink()
b.ask_unclear(now + 61)
check("답은 labels 로", b.db.execute("SELECT answer FROM labels WHERE episode_id=1").fetchall() == [("meowgent",)])
check("답한 구간은 다시 안 묻는다", not (B.INBOX / "brain-ep-1.json").exists())

print("\n모두 통과" if not failed else f"\n실패 {failed}건")
sys.exit(1 if failed else 0)
