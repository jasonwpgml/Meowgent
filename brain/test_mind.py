"""말하는 고양이 루프 점검 (Clef·Codex 없이 가짜로): python3 -I test_mind.py"""
import json, os, sqlite3, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cat_mind as M

failed = 0
def check(name, ok, detail=""):
    global failed
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  → {detail}"))
    failed += 0 if ok else 1


class Clock:
    def __init__(self, t): self.t = t
    def __call__(self): return self.t


class FakeClef:
    def __init__(self): self.calls, self.answer = [], {"speak": {"noul": 0.9}, "mode": {"choice": "judge"}}
    def ask(self, state, qs):
        self.calls.append(state)
        return self.answer


class FakeCodex:
    ready = True
    def __init__(self): self.proc, self.started, self.result = None, [], {"say": "쉬자냥.", "ask": None, "choices": [], "remember": None}
    @property
    def busy(self): return self.proc is not None
    def start(self, job, prompt, model):
        self.proc = (job, prompt)
        self.started.append((job, prompt, model))
    def poll(self):
        if not self.proc: return None
        job, self.proc = self.proc[0], None
        return job, self.result, 1.0


def make(t0, episodes=()):
    data = Path(tempfile.mkdtemp())
    M.LOG = data / "mind.log"
    db = sqlite3.connect(data / "brain.db")
    db.executescript("CREATE TABLE episodes (id INTEGER PRIMARY KEY, start REAL, end REAL, status TEXT, app TEXT, bundle TEXT, ctx TEXT, title TEXT,"
                     " first_event INTEGER, last_event INTEGER, summary TEXT, summary_hash TEXT, judged_hash TEXT, judged_at REAL);"
                     "CREATE TABLE decisions (episode_id INTEGER, qset TEXT, question TEXT, answer TEXT, confidence REAL, probs TEXT, ts REAL, ms INTEGER, final INTEGER);")
    for eid, st, en, status, app, dec in episodes:
        db.execute("INSERT INTO episodes(id,start,end,status,app,title,summary) VALUES(?,?,?,?,?,?,?)",
                   (eid, st, en, status, app, app + " 창", json.dumps({"입력한 글": {"예시": ["비밀 메모"]}, "AI에게 한 질문": ["이거 왜 안 돼"]})))
        for q, (a, c) in dec.items():
            db.execute("INSERT INTO decisions(episode_id,qset,question,answer,confidence) VALUES(?,?,?,?,?)", (eid, "v1", q, a, c))
    db.commit()
    clock = Clock(t0)
    m = M.Mind(data=data, clef=FakeClef(), codex=FakeCodex(), now=clock)
    m.st["active_since"] = t0
    return m, clock, data


T0 = 1_800_000_000.0  # 2027-01-15 08:00 근처. 시각 조건은 cfg 로 맞춘다

# 1) 사용자가 말 걸면 Clef 없이 바로 Codex, 답은 급한 말풍선으로
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
(m.dir / "in").mkdir()
(m.dir / "in" / "1.json").write_text(json.dumps({"text": "안녕 고양이"}))
m.tick()
check("말 걸면 Codex 시작", len(m.codex.started) == 1 and m.codex.started[0][0]["kind"] == "chat")
check("말 걸 땐 Clef 안 부름", m.clef.calls == [])
check("말 건 내용이 프롬프트에", "안녕 고양이" in m.codex.started[0][1])
m.tick()
outs = list((m.dir / "out").glob("*.json"))
check("답이 out/ 에", len(outs) == 1 and json.loads(outs[0].read_text())["urgent"] is True, outs)
convo = M.conversation(m.dir)
check("대화 기록에 양쪽", [c["role"] for c in convo] == ["user", "cat"], convo)

# 2) 막힘 신호 → Clef 통과 → Codex. 같은 구간은 다시 안 함
m, clock, data = make(T0, [(1, T0 - 900, T0, "open", "Code", {"stuck": ("yes", 0.8), "activity": ("coding", 0.9)})])
m.cfg["late_hours"] = [0, 0]
m.tick()
check("막힘 → Clef 한 번", len(m.clef.calls) == 1 and "막혀" in m.clef.calls[0]["신호"], m.clef.calls)
check("막힘 → Codex 시작", len(m.codex.started) == 1 and m.codex.started[0][0]["trig"] == "stuck")
m.tick(); clock.t += 2000; m.tick()
check("같은 막힘은 다시 안 물음", len(m.clef.calls) == 1, len(m.clef.calls))

# 3) 공유 범위: 기본(titles)엔 입력한 글·AI 질문이 안 나간다, full 이면 나간다
p = m.codex.started[0][1]
check("기본 공유엔 입력·질문 없음", "비밀 메모" not in p and "이거 왜 안 돼" not in p and "Code 창" in p, p)
m2, _, _ = make(T0, [(1, T0 - 900, T0, "open", "Code", {"stuck": ("yes", 0.8)})])
m2.cfg.update(share="full", late_hours=[0, 0])
m2.tick()
check("full 이면 AI 질문 포함", "이거 왜 안 돼" in m2.codex.started[0][1])
m3, _, _ = make(T0, [(1, T0 - 900, T0, "open", "Code", {"stuck": ("yes", 0.8)})])
m3.cfg.update(share="labels", late_hours=[0, 0])
m3.tick()
check("labels 면 창 제목도 없음", "Code 창" not in m3.codex.started[0][1])

# 4) Clef 가 아니라고 하면 말 안 함 (토큰 0), 기록은 남겨 다시 묻지 않음
m, clock, data = make(T0, [(1, T0 - 900, T0, "open", "Code", {"stuck": ("yes", 0.8)})])
m.cfg["late_hours"] = [0, 0]
m.clef.answer = {"speak": {"noul": 0.2}, "mode": {"choice": "chat"}}
m.tick(); m.tick()
check("Clef 거절 → Codex 안 부름", m.codex.started == [] and len(m.clef.calls) == 1)

# 5) Clef 가 꺼져 있으면 먼저 말 걸지 않고, 다음에 다시 시도
m, clock, data = make(T0, [(1, T0 - 900, T0, "open", "Code", {"stuck": ("yes", 0.8)})])
m.cfg["late_hours"] = [0, 0]
m.clef.ask = lambda s, q: None
m.tick()
check("Clef 꺼짐 → 말 안 함", m.codex.started == [] and m.st["seen"] == {}, m.st["seen"])

# 6) 간격·횟수 제한
m, clock, data = make(T0)
m.st["spoken"] = [T0 - 100]
check("최근에 말했으면 쉼", not m.budget_ok())
m.st["spoken"] = [T0 - 3000, T0 - 2000, T0 - 1000]
check("한 시간 3번이면 쉼", not m.budget_ok())
m.st["spoken"] = [T0 - 5000]
check("여유 있으면 됨", m.budget_ok())

# 7) 자리 비움: 오래 비웠다 돌아오면 back, 쉬었으면 연속 작업 시간 초기화
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
m.on_afk(T0 - 2000, True)
check("자리 비움 중엔 신호 없음", m.observe([]) == [])
m.on_afk(T0 - 10, False)
sig = m.observe([])
check("돌아오면 back 신호", [s[0] for s in sig] == ["back"], sig)
check("쉬었으니 연속 시간 초기화", m.st["active_since"] == T0 - 10)
m.st["active_since"] = T0 - 6000
check("오래 쉬지 않으면 long_focus", "long_focus" in [s[0] for s in m.observe([])])

# 8) 질문 + 보기 → inbox 에 ? 항목, 답하면 대화 기록으로
m, clock, data = make(T0, [(1, T0 - 900, T0, "open", "Code", {"stuck": ("yes", 0.8)})])
m.cfg["late_hours"] = [0, 0]
m.codex.result = {"say": "뭐 만드는 중이냥?", "ask": "지금 만드는 거 이름이 뭐냥?", "choices": ["Meowgent", "강의"], "remember": "사용자는 고양이를 좋아한다"}
m.tick(); m.tick()
asks = list((data / "inbox").glob("mind-*.json"))
check("보기 있는 질문 → inbox", len(asks) == 1 and json.loads(asks[0].read_text())["choices"][0]["id"] == "Meowgent", asks)
check("같은 질문을 말풍선에 두 번 안 붙임", json.loads(next((m.dir / "out").glob("*.json")).read_text())["text"].count("이름이 뭐냥") == 1)
check("remember → memory.json", m.memory()[-1]["text"] == "사용자는 고양이를 좋아한다")
done = data / "inbox" / "done"; done.mkdir()
o = json.loads(asks[0].read_text()); o["answer"] = "Meowgent"
(done / asks[0].name).write_text(json.dumps(o))
m.tick()
check("답이 대화 기록에", "Meowgent" in M.conversation(m.dir)[-1]["text"])

# 9) 꺼 두면 말 건 것도 버리고 아무것도 안 한다
m, clock, data = make(T0)
(m.dir / "off").touch(); (m.dir / "in").mkdir()
(m.dir / "in" / "1.json").write_text(json.dumps({"text": "안녕"}))
m.tick()
check("꺼짐 → 무시", m.codex.started == [] and not list((m.dir / "in").glob("*.json")))

# 10) Codex 실패 → 말 건 경우엔 대신 사과
m, clock, data = make(T0)
m.codex.result = None
(m.dir / "in").mkdir(); (m.dir / "in" / "1.json").write_text(json.dumps({"text": "안녕"}))
m.tick(); m.tick()
out = [json.loads(f.read_text())["text"] for f in (m.dir / "out").glob("*.json")]
check("실패하면 사과 말풍선", len(out) == 1 and "다시" in out[0], out)

print("\n" + ("모두 통과" if not failed else f"{failed}개 실패"))
sys.exit(1 if failed else 0)
