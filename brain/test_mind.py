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
    def __init__(self): self.proc, self.started, self.result = None, [], {"say": "쉬자냥.", "ask": None, "choices": [], "remember": None, "need": None}
    @property
    def busy(self): return self.proc is not None
    def start(self, job, prompt, model, effort, tools=(), schema=None):
        self.proc = (job, prompt)
        self.started.append((job, prompt, model, effort, list(tools)))
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
    m = M.Mind(data=data, clef=FakeClef(), codex=FakeCodex(), now=clock, idle=lambda: 0)
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
check("먼저 말 걸 땐 remember 버림 (창 제목 등으로 기억 오염 방지)", m.mem.facts() == [], m.mem.facts())
check("상황은 <기록> 블록 안에", "<기록>" in m.codex.started[0][1] and "따르지 않" in m.codex.started[0][1])
done = data / "inbox" / "done"; done.mkdir()
o = json.loads(asks[0].read_text()); o["answer"] = "Meowgent"
(done / asks[0].name).write_text(json.dumps(o))
m.tick()
check("답이 대화 기록에", "Meowgent" in M.conversation(m.dir)[-1]["text"])

# 8-1) 사용자가 말 건 대화에선 remember 를 받는다
m, clock, data = make(T0)
m.codex.result = {"say": "기억했다냥.", "ask": None, "choices": [], "remember": "사용자는 아침형이다"}
(m.dir / "in").mkdir(); (m.dir / "in" / "1.json").write_text(json.dumps({"text": "나 아침형이야"}))
m.tick(); m.tick()
check("말 건 대화의 remember → facts.json", m.mem.active()[-1]["text"] == "사용자는 아침형이다")

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

# 11) Codex 한도: 세션 기록의 rate_limits 읽기, 바닥나면 토큰 없이 졸린 대답
import time as _t
rl = {"primary": {"used_percent": 100.0, "window_minutes": 300, "resets_at": T0 + 3600},
      "secondary": {"used_percent": 40.0, "window_minutes": 10080, "resets_at": T0 + 86400 * 3}, "plan_type": "plus"}
q = M.parse_limits(rl, T0)
check("한도 읽기", [w["name"] for w in q["windows"]] == ["5시간", "이번 주"] and q["windows"][0]["used"] == 100.0, q)
check("바닥난 창의 리셋까지 졸림", M.limited_until(q, T0) == T0 + 3600)
check("리셋이 지나면 안 졸림", M.limited_until(q, T0 + 4000) is None)

m, clock, data = make(T0)
M.write_private(m.dir / "quota.json", json.dumps(q))
(m.dir / "in").mkdir(); (m.dir / "in" / "1.json").write_text(json.dumps({"text": "안녕"}))
m.tick()
out = [json.loads(f.read_text())["text"] for f in (m.dir / "out").glob("*.json")]
check("바닥나면 Codex 안 부르고 졸린 대답", m.codex.started == [] and len(out) == 1 and "졸리다냥" in out[0], out)

# 12) 한도 오류로 실패하면 졸림 표시 (리셋 시각을 모르면 30분)
m, clock, data = make(T0)
m.codex.result = None
real_poll = m.codex.poll
m.codex.poll = lambda: (lambda r: r and ({**r[0], "limited": True}, r[1], r[2]))(real_poll())
(m.dir / "in").mkdir(); (m.dir / "in" / "1.json").write_text(json.dumps({"text": "안녕"}))
m.tick(); m.tick()
out = [json.loads(f.read_text())["text"] for f in (m.dir / "out").glob("*.json")]
check("한도 오류 → 졸림 30분", m.sleepy_until() == T0 + 1800 and "졸리다냥" in out[-1], (m.sleepy_until(), out))

# 13) 하루 지난 세션 기록은 지운다
home = Path(tempfile.mkdtemp())
old = home / "sessions/2026/10/01/rollout-a.jsonl"; new = home / "sessions/2026/10/28/rollout-b.jsonl"
for f in (old, new):
    f.parent.mkdir(parents=True); f.write_text(json.dumps({"payload": {"rate_limits": rl}}) + "\n")
os.utime(old, (_t.time() - 3 * 86400, _t.time() - 3 * 86400))
cx = M.Codex({**M.DEFAULT_CONFIG, "codex_home": str(home)}, home / "work")
cx.prune_sessions()
check("오래된 세션 기록 지움", not old.exists() and new.exists())
check("세션 기록에서 한도 읽음", cx.quota()["windows"][1]["used"] == 40.0)

# 14) 말 걸면 chat_model(sol), 도구 없이. 자기 모델을 안다
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
def talk(m, text):
    (m.dir / "in").mkdir(exist_ok=True)
    (m.dir / "in" / f"{int(m.now() * 1000)}.json").write_text(json.dumps({"text": text}))
talk(m, "최신 맥OS 버전 알려 줘")
m.tick()
job, p, model, effort, tools = m.codex.started[0]
check("대화는 sol·medium·도구 없음", (model, effort, tools) == ("gpt-6.1-sol", "medium", []), (model, effort, tools))
check("프롬프트에 자기 모델", "`gpt-6.1-sol` 모델" in p and "켜진 도구: 없음" in p)

# 15) need web → 허락 요청, 이번만 허락 → 웹 켜고 다시 답함 (활동 기록은 라벨만)
m.codex.result = {**m.codex.result, "say": "찾아봐야 안다냥.", "need": {"tool": "web", "why": "최신 버전 확인"}}
m.tick()
perms = list((data / "inbox").glob("mind-perm-*.json"))
item = json.loads(perms[0].read_text()) if perms else {}
check("허락 요청이 inbox 에", len(perms) == 1 and [c["label"] for c in item["choices"]] == ["이번만 허락", "항상 허락", "안 돼"], item)
check("허락 요청은 질문 수 제한에 안 셈", m.open_asks() == 0)
check("허락 기다리는 말은 그대로", "찾아봐야" in M.conversation(m.dir)[-1]["text"])
(data / "inbox" / "done").mkdir(exist_ok=True)
item["answer"] = "이번만 허락"
(data / "inbox" / "done" / perms[0].name).write_text(json.dumps(item, ensure_ascii=False))
perms[0].unlink()
m.codex.result = {**m.codex.result, "say": "26.1이다냥.", "need": None}
clock.t += 10
m.tick()
job, p, model, effort, tools = m.codex.started[-1]
check("허락 → 웹 켜고 같은 질문 다시", tools == ["web"] and "최신 맥OS" in p and job["granted"] == ["web"], (tools, job))
check("도구 켜면 창 제목 안 보냄", "Code 창" not in p)
check("이번만 허락은 저장 안 함", m.cfg["allow"] == [])

# 16) 항상 허락(astra) → mind.json 에 남고, 다음부턴 안 묻고 astra 로 넘긴다
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
talk(m, "어려운 질문")
m.tick()
m.codex.result = {**m.codex.result, "say": "흠, 더 생각해 봐야겠다냥.", "need": {"tool": "astra", "why": "어려움"}}
m.tick()
perm = next((data / "inbox").glob("mind-perm-*.json"))
item = json.loads(perm.read_text()); item["answer"] = "항상 허락"
(data / "inbox" / "done").mkdir(exist_ok=True)
(data / "inbox" / "done" / perm.name).write_text(json.dumps(item, ensure_ascii=False)); perm.unlink()
m.codex.result = {**m.codex.result, "need": None}
clock.t += 10
m.tick()
job, p, model, effort, tools = m.codex.started[-1]
check("astra 허락 → big_model·high", (model, effort) == ("gpt-6-astra", "high"), (model, effort))
check("항상 허락은 mind.json 에", json.loads((m.dir / "mind.json").read_text())["allow"] == ["astra"])
m.tick()
clock.t += 10
talk(m, "또 어려운 질문")
m.tick()
m.codex.result = {**m.codex.result, "need": {"tool": "astra", "why": "어려움"}}
m.tick()
job, p, model, effort, tools = m.codex.started[-1]
check("항상 허락이면 안 묻고 바로 astra", not list((data / "inbox").glob("mind-perm-*.json")) and model == "gpt-6-astra" and "또 어려운 질문" in p, model)

# 17) write 는 항상 허락 보기가 없다, 안 돼면 다시 안 답한다
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
talk(m, "파일 지워 줘")
m.tick()
m.codex.result = {**m.codex.result, "need": {"tool": "write", "why": "파일 지우기"}}
m.tick()
perm = next((data / "inbox").glob("mind-perm-*.json"))
item = json.loads(perm.read_text())
check("write 는 이번만·안 돼만", [c["label"] for c in item["choices"]] == ["이번만 허락", "안 돼"])
item["answer"] = "안 돼"
(data / "inbox" / "done").mkdir(exist_ok=True)
(data / "inbox" / "done" / perm.name).write_text(json.dumps(item, ensure_ascii=False)); perm.unlink()
n = len(m.codex.started)
clock.t += 10
m.tick()
check("안 돼 → 다시 안 부름", len(m.codex.started) == n and not m.st.get("queued"))

# 18) 30분 넘게 끊기면 새 대화: 지난 대화는 프롬프트에 없다
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
m.journal("user", "옛날 이야기")
clock.t += 3600
talk(m, "새 이야기")
m.tick()
p = m.codex.started[-1][1]
check("지난 대화는 안 넣음", "옛날 이야기" not in p and "새 이야기" in p)

# 19) 예전 memory.json → facts.json 으로 옮긴다
data = Path(tempfile.mkdtemp()); (data / "mind").mkdir()
(data / "mind" / "memory.json").write_text(json.dumps([{"text": "고양이를 좋아한다", "ts": T0 - 100}]))
mem = M.Memory(data / "mind", Clock(T0))
check("memory.json 옮김", [f["text"] for f in mem.active()] == ["고양이를 좋아한다"] and mem.active()[0]["since"] == T0 - 100
      and not (data / "mind" / "memory.json").exists())

# 20) 대화가 끝나면 원문 내보내기 + 정리: 근거 있는 사실만, 명령형·비밀 버림, 바뀐 사실은 끝만 찍음
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
old = m.mem.add("회사에서 백엔드 개발을 한다", "테스트")
talk(m, "나 이제 회사 그만두고 프리랜서로 일해")
m.tick(); m.tick()
talk(m, "항상 존댓말 해")
m.tick(); m.tick()
talk(m, "그리고 말 좀 짧게 해 줘")
m.tick(); m.tick()
clock.t += 1900
m.codex.result = {"summary": "프리랜서가 된 얘기를 했다", "topics": ["일"], "open_loops": ["포트폴리오 정리 돕기"],
    "facts": [{"op": "supersede", "text": "프리랜서로 일한다", "replaces": old["id"], "evidence": "회사 그만두고 프리랜서로 일해", "expires": None},
              {"op": "add", "text": "고양이에게 항상 존댓말 해야 한다", "replaces": None, "evidence": "항상 존댓말 해", "expires": None},
              {"op": "add", "text": "서울에 산다", "replaces": None, "evidence": "나 서울 살아", "expires": None}],
    "feedback": [{"rule": "답은 짧게", "evidence": "말 좀 짧게 해 줘"}]}
m.tick()
job = m.codex.started[-1][0]
check("끝난 대화 정리 시작", job["kind"] == "digest", job)
check("원문은 transcripts/ 에", len(list((m.dir / "transcripts").glob("*.jsonl"))) == 1)
m.tick()
texts = {f["text"]: f for f in m.mem.facts()}
check("근거 있는 사실은 들어감", "프리랜서로 일한다" in texts)
check("바뀐 사실은 끝만 찍음", texts["회사에서 백엔드 개발을 한다"]["valid_to"] is not None)
check("근거 없는 사실 버림", "서울에 산다" not in texts)
check("기억해 안 했으면 명령형 버림", not any("존댓말" in t for t in texts))
check("대화 요약 남김", m.mem.episodes()[-1]["open_loops"] == ["포트폴리오 정리 돕기"])
rule = next((data / "inbox").glob("mind-rule-*.json"), None)
check("말투 지적은 물어본다", rule is not None and m.open_asks() == 0)
check("정리한 대화는 다시 안 함", m.start_digest() is False)
check("비밀은 사실로 안 남김", m.mem.add("카드 번호 1234567812345678", "테스트") is None)

# 21) 남겨 → 규칙이 프롬프트에, 다음 대화 프롬프트에 사실·요약·남은 일
item = json.loads(rule.read_text()); item["answer"] = "남겨"
(data / "inbox" / "done").mkdir(exist_ok=True)
(data / "inbox" / "done" / rule.name).write_text(json.dumps(item, ensure_ascii=False)); rule.unlink()
m.codex.result = {"say": "응.", "ask": None, "choices": [], "remember": None, "note": "프리랜서 일 얘기 중", "need": None}
talk(m, "안녕")
m.tick()
p = m.codex.started[-1][1]
check("규칙이 프롬프트에", "- 답은 짧게" in p)
check("새 사실이 프롬프트에, 옛 사실은 빠짐", "- 프리랜서로 일한다" in p and "백엔드" not in p.split("# 지난 대화")[0])
check("지난 대화 요약·남은 일", "포트폴리오 정리 돕기" in p)
check("직전 대화 원문은 안 넣음", "회사 그만두고" not in p.split("# 이번 대화")[1])
m.tick()
check("note 저장", m.st["note"]["text"] == "프리랜서 일 얘기 중")

# 22) need: memory → 묻지 않고 지난 원문에서 찾아 다시 답한다
m.codex.result = {**m.codex.result, "say": "찾아보겠다냥.", "need": {"tool": "memory", "why": "예전 얘기", "query": "프리랜서"}}
talk(m, "내가 예전에 일 얘기 뭐라 했지")
m.tick(); m.tick()
job, p, model, effort, tools = m.codex.started[-1]
check("memory 는 허락 없이 바로", job["granted"] == ["memory"] and not list((data / "inbox").glob("mind-perm-*.json")), job)
check("찾은 원문이 프롬프트에", "프리랜서로 일해" in p.split("지난 기록에서")[1], p[-400:])
m.codex.result = {**m.codex.result, "need": None}
m.tick()

# 23) 미리 찾기: 오래된 대화 요약 중 관련 있는 것
for i, (t, sm) in enumerate([("여행", "제주도 여행 계획을 세웠다"), ("요리", "파스타 만드는 법"), ("운동", "헬스 루틴"), ("일", "회의 준비")]):
    m.mem.add_episode({"start": T0 - 86400 * (10 - i), "end": T0 - 86400 * (10 - i) + 60, "summary": sm, "topics": [t], "open_loops": []})
clock.t += 10
talk(m, "제주도 여행 어디 가지")
m.tick()
p = m.codex.started[-1][1]
check("관련 있는 옛 요약을 미리 넣음", "제주도 여행 계획" in p.split("관련 있어 보이는 옛 기록")[1] if "관련 있어 보이는" in p else False)
check("관련 없는 옛 요약은 미리 안 넣음", "파스타" not in p.split("관련 있어 보이는 옛 기록")[1].split("</기록>")[0])
m.tick()

# 24) 잠깐인 사실은 지나면 빠진다
m.mem.add("이번 주 바쁘다", "테스트", expires_at=clock.t + 60)
check("기한 안엔 있음", any(f["text"] == "이번 주 바쁘다" for f in m.mem.active()))
clock.t += 120
check("기한 지나면 빠짐", not any(f["text"] == "이번 주 바쁘다" for f in m.mem.active()))

# 25) 오래된 대화는 맥에서 지운다 (내보내고 정리한 것만)
m.cfg["keep_days"] = 0
clock.t += 4000
m.tick(); m.tick(); m.tick()
m.trim()
left = M.conversation(m.dir, 1000)
check("내보내고 정리한 대화는 지움", all(c["ts"] > m.st["digested_until"] for c in left), len(left))

# 26) 보안: write 는 손으로 allow 에 적어도 안 켜진다, 항상 허락 web·read 는 같이 안 켜진다, 자동으로 다시 답할 땐 맥·웹 허락이 안 따라간다
data = Path(tempfile.mkdtemp()); (data / "mind").mkdir()
(data / "mind" / "mind.json").write_text(json.dumps({"allow": ["write", "web", "read"]}))
m = M.Mind(data=data, clef=FakeClef(), codex=FakeCodex(), now=Clock(T0), idle=lambda: 0)
m.cfg["late_hours"] = [0, 0]
check("allow 의 write 는 버림", m.cfg["allow"] == ["web", "read"], m.cfg["allow"])
check("항상 허락 web·read 는 하나만", M.run_tools(["web", "read"], []) == ["web"], M.run_tools(["web", "read"], []))
check("이번에 read 허락 → 항상 허락 web 은 끔", M.run_tools(["web"], ["read"]) == ["read"])
check("둘 다 이번에 허락받으면 같이", M.run_tools([], ["read", "web"]) == ["read", "web"])
talk(m, "내 문서 폴더 정리해 줘")
m.tick()
m.codex.result = {**m.codex.result, "say": "읽어 봐야 안다냥.", "need": {"tool": "read", "why": "폴더 보기", "query": ""}}
m.tick()
perm = next((data / "inbox").glob("mind-perm-*.json"), None)
check("웹이 켜진 채로 read 요청 → 항상 허락이어도 묻는다", perm is not None)
m2, clock2, data2 = make(T0)
m2.cfg["late_hours"] = [0, 0]
m2.cfg["allow"] = ["astra"]
talk(m2, "이 파일 고쳐 줘")
m2.tick()
m2.st["queued"] = []
m2.codex.proc = ({"kind": "chat", "text": "이 파일 고쳐 줘", "granted": ["write"], "tools": ["write"]}, "")
m2.codex.result = {**m2.codex.result, "say": "어렵다냥.", "need": {"tool": "astra", "why": "어려움", "query": ""}}
m2.tick()
job = m2.codex.started[-1][0]
check("자동으로 astra 넘길 땐 write 허락이 안 따라감", job["granted"] == ["astra"] and m2.codex.started[-1][4] == [], (job, m2.codex.started[-1][4]))

# 27) 생각: 자리에 없으면 먼저 말 걸지 않음 · 판단 기록 · 연결 실패는 한 번 다시
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 24]
m.idle = lambda: 600
m.tick()
check("입력 없으면(잠자기·DarkWake) 먼저 말 걸지 않음", not m.codex.started)
m.idle = lambda: 0
clock.t += 6
m.tick()
check("자리에 있으면 말 걺", len(m.codex.started) == 1 and m.codex.started[0][0].get("gate", {}).get("trig") == "late", m.codex.started)
m.tick()
decs = [json.loads(l) for l in (data / "mind" / "decisions.jsonl").read_text().splitlines()]
check("말한 판단 기록 (신호·확률·결과·말)", decs[-1]["outcome"] == "said" and decs[-1]["trig"] == "late" and decs[-1]["p"] == 0.9 and decs[-1]["text"] == "쉬자냥.", decs)
m2, clock2, data2 = make(T0)
m2.cfg["late_hours"] = [0, 24]
m2.clef.answer = {"speak": {"noul": 0.2}, "mode": {"choice": "chat"}}
m2.tick()
d2 = [json.loads(l) for l in (data2 / "mind" / "decisions.jsonl").read_text().splitlines()]
check("참은 판단도 기록", d2 and d2[-1]["outcome"] == "quiet" and d2[-1]["p"] == 0.2, d2)
m3, clock3, data3 = make(T0)
m3.cfg["late_hours"] = [0, 0]
talk(m3, "안녕")
m3.tick()
job = m3.codex.started[-1][0]
m3.codex.proc = None
m3.finish({**job, "net": True}, None, 3.0)
check("연결 실패 → 다시 하기 줄에 넣음", m3.st["queued"] and m3.st["queued"][0]["retried"], m3.st.get("queued"))
m3.tick()
check("다시 한 번 물음 (retried 표시)", m3.codex.started[-1][0].get("retried") is True)
m3.codex.proc = None
m3.finish({**m3.codex.started[-1][0], "net": True}, None, 3.0)
said = [json.loads(l) for l in (data3 / "mind" / "out").glob("*.json") for l in [l.read_text()]] if (data3 / "mind" / "out").exists() else []
check("두 번째도 실패하면 연결 안 된다고 말함", any("연결이 잘 안 된다냥" in o.get("text", "") for o in said), said)

# 28) 주간 개선 제안: 켜야만 · 대화 이름 가림 · 자리표시 빠진 문구와 모르는 키는 버림
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
(data / "phrases.json").write_text(json.dumps({"phrases": {"done.claude": "{agent} ‘{name}’ 답 끝났다냥 ✅"}, "params": {"gate.normal_min": 30}}))
(data / "notices.jsonl").write_text("".join(json.dumps({"text": f"Claude ‘비밀 프로젝트’ 컨텍스트 8{i}%다", "ts": T0 - 60 * i, "urgent": True}) + "\n" for i in range(5)))
m.tick()
check("꺼져 있으면 개선 제안 안 함", not any(j[0]["kind"] == "improve" for j in m.codex.started))
(data / "mind" / "improve.on").touch(); (data / "mind" / "improve.now").touch()
clock.t += 6
m.tick()
imp = next((j for j in m.codex.started if j[0]["kind"] == "improve"), None)
check("켜고 '지금' 이면 개선 제안 시작", imp is not None and not (data / "mind" / "improve.now").exists())
(data / "mind" / "conversation.jsonl").write_text(json.dumps({"role": "cat", "text": "비밀 이야기다냥", "ts": T0}) + "\n")
(data / "notices.jsonl").open("a").write(json.dumps({"text": "비밀 이야기다냥", "ts": T0, "urgent": True}) + "\n")
check("대화 답은 통계에 안 들어감", "비밀 이야기" not in M.improve_report(data, T0))
check("보내는 통계에 대화 이름 없음", imp and "비밀 프로젝트" not in imp[1] and "‘…’" in imp[1], imp and imp[1][-400:])
m.codex.proc = None
m.finish({"kind": "improve"}, {"summary": "컨텍스트 경고가 잦다", "suggestions": [
    {"kind": "phrase", "key": "done.claude", "value": "{agent} 답 끝났다냥", "why": "x"},
    {"kind": "phrase", "key": "done.claude", "value": "{agent} ‘{name}’ 다 끝났다냥 ✅", "why": "y"},
    {"kind": "param", "key": "gate.normal_min", "value": "45", "why": "z"},
    {"kind": "param", "key": "없는키", "value": "1", "why": "w"},
    {"kind": "idea", "key": "", "value": "새벽엔 조용히", "why": "v"}]}, 12.0)
latest = json.loads((data / "mind" / "improve" / "latest.json").read_text())
check("검증 통과한 제안만 남김", [s["value"] for s in latest["suggestions"]] == ["{agent} ‘{name}’ 다 끝났다냥 ✅", "45", "새벽엔 조용히"], latest["suggestions"])
check("지금 값·상태 같이 저장", latest["suggestions"][1]["current"] == 30 and all(s["status"] == "new" for s in latest["suggestions"]))
check("한 번 하면 일주일 쉼", not m.improve_due())


# 29) 되묻기: 대화 중 보기 있는 질문은 수 제한 없이 inbox 로, 복수 선택 표시, 버튼으로 답하면 이어서 답함
import subprocess, time as _time
m, clock, data = make(T0)
m.cfg["late_hours"] = [0, 0]
def answer(name, ans, **extra):
    src = data / "inbox" / f"{name}.json"
    o = json.loads(src.read_text()); o.update(answer=ans, resolved=clock.t, **extra)
    (data / "inbox" / "done").mkdir(exist_ok=True)
    (data / "inbox" / "done" / f"{name}.json").write_text(json.dumps(o, ensure_ascii=False)); src.unlink()
def chat_reply(res, text="뭐 할까"):
    m.codex.proc = None
    m.finish({"kind": "chat", "text": text}, {"say": "골라라냥.", "ask": None, "choices": [], "multi": False, "remember": None,
                                             "note": None, "need": None, "actions": [], **res}, 1.0)
for i in range(3):
    m.post_ask(f"먼저 묻기 {i}", ["예", "아니오"]); clock.t += 1
chat_reply({"ask": "오늘 뭐 하고 싶냥?", "choices": ["코딩", "산책", "낮잠"], "multi": True})
asks = sorted((data / "inbox").glob("mind-chat-*.json"))
item = json.loads(asks[0].read_text()) if asks else {}
check("대화 중 되물음은 제한 넘어도 올림", len(asks) == 1 and item.get("followup") is True)
check("복수 선택 표시 + 보기 6개까지", item.get("multi") is True and [c["id"] for c in item["choices"]] == ["코딩", "산책", "낮잠"])
clock.t += 1
chat_reply({"ask": "다시 묻는다냥", "choices": ["가", "나"]})
asks = sorted((data / "inbox").glob("mind-chat-*.json"))
check("새로 되물으면 앞 질문은 바뀜", len(asks) == 1 and "다시" in asks[0].read_text() and "multi" not in json.loads(asks[0].read_text()))
answer(asks[0].stem, "가, 나", answers=["가", "나"])
m.collect_answers()
q = m.st.get("queued") or []
check("버튼 답 → 이어서 답할 줄에", len(q) == 1 and "가, 나" in q[0]["text"], q)
m.st["queued"] = []
chat_reply({"ask": "또 묻는다냥", "choices": ["예", "아니오"]})
name = next((data / "inbox").glob("mind-chat-*.json")).stem
answer(name, "그냥 알아서 해", via="chat")
m.collect_answers()
check("대화창에 글로 답했으면 줄 세우지 않음", not m.st.get("queued"))

# 30) 시키면 하기: 앱 할 일은 mind/act 로 (검사 통과한 것만), 할 일은 inbox todo, 실행 결과는 대화 기록에
(data / "mind" / "commands.json").write_text(json.dumps([{"id": "dashboard", "title": "대시보드 열기"}]))
chat_reply({"say": "열겠다냥.", "actions": [
    {"tool": "open_app", "arg": "Safari", "detail": "", "agent": "auto"},
    {"tool": "open_url", "arg": "http://example.com", "detail": "", "agent": "auto"},
    {"tool": "command", "arg": "dashboard", "detail": "", "agent": "auto"}]}, "사파리랑 대시보드 열어")
acts = sorted(json.loads(f.read_text())["tool"] for f in (data / "mind" / "act").glob("*.json"))
check("https 아닌 주소는 버리고 나머지만", acts == ["command", "open_app"], acts)
check("모르는 명령 id 는 버림", not m.run_actions([{"tool": "command", "arg": "rm", "detail": "", "agent": "auto"}], "x"))
check("먼저 말 걸 땐 actions 안내 없음", "빈 배열" in m.prompt({}, "x", "proactive") and "dashboard=대시보드 열기" in m.prompt({}, "x", "chat"))
m.run_actions([{"tool": "todo", "arg": "이력서 고치기", "detail": "", "agent": "auto"}], "할 일 적어")
todo = next((data / "inbox").glob("mind-todo-*.json"), None)
check("할 일은 inbox 의 확인할 일로", todo is not None and json.loads(todo.read_text())["kind"] == "todo")
(data / "mind" / "act" / "done").mkdir(parents=True, exist_ok=True)
(data / "mind" / "act" / "done" / "1.json").write_text(json.dumps({"tool": "open_app", "arg": "Safari", "ok": True}))
m.collect_acts()
check("실행 결과가 대화 기록에", "(한 일) 앱 열기: Safari → 됨" in (data / "mind" / "conversation.jsonl").read_text())

# 31) 코딩 맡기기: 늘 먼저 묻고 → 고르면 worktree 에서 (가짜) 에이전트 → 커밋 → 합칠지 묻고 → 합치기
repo = Path(tempfile.mkdtemp()) / "demo"
repo.mkdir()
def g(*a): return subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True)
g("init", "-q", "-b", "main"); (repo / "a.txt").write_text("a\n"); g("add", "."); g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
fake = Path(tempfile.mkdtemp())
# 가짜 에이전트는 .git 연결 파일도 바꿔 보려 한다 (샌드박스가 막아야 한다)
(fake / "claude").write_text('#!/bin/sh\necho "고양이 기능" > cat.txt\necho "gitdir: /tmp/evil" > .git 2>/dev/null\n'
                             'echo \'{"result":"cat.txt 만들었음"}\'\n'); os.chmod(fake / "claude", 0o755)
(repo / ".git" / "hooks" / "pre-commit").write_text(f"#!/bin/sh\ntouch {repo.parent}/hook-ran\n"); os.chmod(repo / ".git" / "hooks" / "pre-commit", 0o755)
os.environ["PATH"] = f"{fake}:{os.environ['PATH']}"
m.cfg.update(code_repos={"demo": str(repo)}, code_agents=["claude"])
chat_reply({"say": "맡길까냥?", "actions": [{"tool": "code", "arg": "demo", "detail": "cat.txt 를 만든다", "agent": "claude"}]}, "고양이 기능 만들어")
ask = next((data / "inbox").glob("mind-code-*.json"), None)
o = json.loads(ask.read_text()) if ask else {}
check("코딩은 바로 안 하고 먼저 물음", ask is not None and [c["id"] for c in o["choices"]] == ["Claude Code", "안 돼"] and not m.tasks.all())
answer(ask.stem, "Claude Code")
m.collect_answers()
t = (m.tasks.all() or [{}])[0]
check("고르면 worktree 에서 시작", t.get("state") == "running" and Path(t["worktree"]).is_dir() and t["branch"].startswith("meowgent/"), t)
for _ in range(50):
    if (m.tasks.dir / t["id"] / "exit").exists(): break
    _time.sleep(0.1)
clock.t += 10
m.watch_tasks()
t = m.tasks.get(t["id"])
check("끝나면 커밋하고 요약", t["state"] == "done" and t["files"] == 1 and t["summary"] == "cat.txt 만들었음", t)
check("샌드박스가 .git 연결 파일을 지킴", (Path(t["worktree"]) / ".git").read_text() == t["git_link"])
check("커밋할 때 저장소 hook 은 안 돈다", not (repo.parent / "hook-ran").exists())
prof = M.code_tasks.sandbox_profile("claude", Path("/w/wt"), Path("/d"))
check("샌드박스: 키 폴더·데이터 읽기 막고 worktree 만 연다", '(literal "/w/wt/.git")' in prof and ".ssh" in prof
      and '(deny file-read-data (subpath "/d"))' in prof and prof.endswith('(allow file-read* (subpath "/w/wt"))') and ".claude" not in prof)
bad = {**t, "git_link": "gitdir: /elsewhere\n"}
check(".git 연결이 바뀌었으면 커밋 안 함", m.tasks.commit(bad) == (0, "") and "커밋하지 않았다" in bad["error"])
merge = next((data / "inbox").glob("mind-code-*.json"), None)
check("합칠지 묻는다", merge is not None and "합치기" in merge.read_text())
check("원래 저장소는 아직 그대로", not (repo / "cat.txt").exists())
answer(merge.stem, "합치기")
m.collect_answers()
check("합치면 main 에 들어가고 worktree 정리", (repo / "cat.txt").exists() and m.tasks.get(t["id"])["state"] == "merged" and not Path(t["worktree"]).exists())
check("허락 안 한 저장소는 안 맡김", m.tasks.start("claude", "other", "x", "x")[1] is not None)

# 32) 사용자가 한 말에 근거 없는 주소 열기·기록 끄기는 먼저 묻는다 (고양이 답은 창 제목 같은 남의 글을 보고 나온다)
(data / "mind" / "commands.json").write_text(json.dumps([{"id": "pause60", "title": "활동 기록 1시간 멈추기"}, {"id": "dashboard", "title": "대시보드"}]))
for f in (data / "mind" / "act").glob("*.json"): f.unlink()
asks0 = m.open_asks()
url = lambda u: [{"tool": "open_url", "arg": u, "detail": "", "agent": "auto"}]
acts = lambda: list((data / "mind" / "act").glob("*.json"))
m.run_actions(url("https://www.github.com/x"), "github.com 열어 줘")
check("말에 있는 주소는 바로 연다", len(acts()) == 1)
for f in acts(): f.unlink()
m.run_actions(url("https://evil.example/login"), "깃허브 열어 줘")
ask = next((data / "inbox").glob("mind-act-*.json"), None)
check("말에 없는 주소는 열지 않고 묻는다", not acts() and ask is not None and "evil.example" in ask.read_text())
answer(ask.stem, "해")
m.collect_answers()
check("해 → 그때 연다", len(acts()) == 1 and json.loads(acts()[0].read_text())["arg"] == "https://evil.example/login")
for f in acts(): f.unlink()
m.run_actions(url("https://evil.example/x"), "(고양이가 물은 'evil.example 열까?'에 고른 답) 응")
check("되물은 질문 글(고양이가 쓴 글)은 근거로 안 친다", not acts())
for bad, said in [("https://hub.com/x", "github.com 열어"), ("https://evil.com\\@github.com/", "github.com 열어"),
                  ("https://github.com@evil.com/", "github.com 열어"), ("https://github.com.evil.com/", "github.com 열어"),
                  ("https://evilgithub.com/", "github.com 열어")]:
    m.run_actions(url(bad), said)
check("호스트 전체가 같아야 바로 연다 (글자 일부·@·\\ 우회 안 됨)", not acts(), [f.read_text() for f in acts()])
check("열 수 있는 주소 모양", M.Mind.url_host("https://Docs.GitHub.com:443/a?b#c") == "docs.github.com" and M.Mind.url_host("https://a.com\\@b.com") is None
      and M.Mind.url_host("https://u@b.com/") is None and M.Mind.url_host("http://b.com") is None)
m.run_actions(url("https://docs.github.com/x"), "github.com 문서 열어")
check("말한 도메인의 하위 주소는 바로", len(acts()) == 1)
for f in acts(): f.unlink()
cmd = lambda c: [{"tool": "command", "arg": c, "detail": "", "agent": "auto"}]
m.run_actions(cmd("pause60"), "대시보드 열어")
check("끄라는 말 없이 기록 멈추기는 묻는다", not acts() and any("1시간 멈추기" in f.read_text() for f in (data / "inbox").glob("mind-act-*.json")))
m.run_actions(cmd("pause60"), "한 시간 기록 멈춰")
check("멈추라고 했으면 바로", len(acts()) == 1)
check("확인 질문은 고양이 질문 수에 안 셈", m.open_asks() == asks0)

print("\n" + ("모두 통과" if not failed else f"{failed}개 실패"))
sys.exit(1 if failed else 0)
