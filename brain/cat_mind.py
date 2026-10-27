#!/usr/bin/env python3
"""말하는 고양이: 평소엔 결정론적 코드로만 돌고, 일이 생겼을 때만 Codex에게 고양이 말을 받아 온다.

  python3 cat_mind.py run      # 계속 실행 (launchd가 띄움)
  python3 cat_mind.py say "안녕"  # 고양이에게 한마디 (앱 메뉴와 같은 길) 하고 답을 기다려 출력
  python3 cat_mind.py status   # 상태 요약

흐름 (docs/CAT_MIND.md):
  1. 1초마다 mind/in(사용자가 건 말)을, 5초마다 brain.db(Clef 판단)·actlog.db(자리 비움)를 읽는다. 토큰 0.
  2. 규칙으로 신호를 고른다: 말 걸어 옴, 오래 비웠다 돌아옴, 막힘, 오래 쉬지 않음, 작업 전환, 딴짓, 늦은 밤, 오래 조용함.
  3. 먼저 말 건 게 아니면 횟수·간격 제한을 보고, 로컬 Clef에게 "지금 말 걸 만한가, 어떤 식으로"를 묻는다. 토큰 0.
  4. 통과하면 Codex(고양이 전용 CODEX_HOME)를 한 번 부른다. 답은 mind/out → 앱이 말풍선으로, 질문은 inbox → 얼굴 옆 ?.

표준 라이브러리만 쓴다. actlog.db·brain.db는 읽기 전용으로 연다.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

DATA = Path.home() / "Library/Application Support/Meowgent"
MIND = DATA / "mind"
LOG = MIND / "mind.log"

DEFAULT_CONFIG = {
    "clef_url": "http://localhost:8010",
    "codex_home": str(Path.home() / ".codex-meowgent"),
    "codex_bin": "",                 # 비우면 PATH·Homebrew 에서 찾는다
    "model": "gpt-6-luna",           # 먼저 말 걸 때
    "chat_model": "gpt-6-luna",      # 사용자가 말 걸었을 때
    "effort": "low",
    "timeout_s": 90,
    "share": "titles",               # Codex에 보내는 범위: labels | titles | full (아래 situation 참고)
    "gate": 0.5,                     # Clef "지금 말 걸 만한가" 확률이 이 이상이어야 말한다
    "min_gap_s": 900,                # 먼저 말 거는 간격
    "max_per_hour": 3,
    "max_per_day": 24,
    "ask_open_max": 2,               # 안 답한 고양이 질문이 이만큼이면 더 묻지 않는다
    "back_min_s": 1200,              # 이만큼 비웠다 돌아오면 반긴다
    "break_min_s": 300,              # 이만큼 비우면 쉰 것으로 친다
    "long_focus_s": 5400,            # 쉬지 않고 이만큼 일하면 쉬자고 한다
    "stuck_min_s": 480,
    "drift_min_s": 1500,
    "work_hours": [10, 19],          # 딴짓 신호는 이 시간에만
    "late_hours": [1, 5],            # 이 시간에 깨어 있으면 한 번 챙긴다
    "quiet_s": 10800,                # 이만큼 아무 말 없었으면 궁금한 걸 하나 묻는다
}

# 신호: (우선순위, Clef에 보여 줄 설명). 숫자가 작을수록 먼저
TRIGGERS = {
    "stuck": (1, "사용자가 같은 문제를 반복 시도하며 막혀 있는 것 같다"),
    "back": (2, "사용자가 한참 자리를 비웠다가 방금 돌아왔다"),
    "long_focus": (3, "사용자가 오랫동안 쉬지 않고 일하고 있다"),
    "late": (4, "늦은 밤인데 사용자가 아직 깨어서 컴퓨터를 하고 있다"),
    "drift": (5, "일하는 시간에 휴식·영상·쇼핑 같은 딴짓을 오래 하고 있다"),
    "switch": (6, "사용자가 하던 작업을 마치고 다른 프로젝트로 넘어갔다"),
    "notable": (7, "방금 작업 구간에 결정·완료·중요한 발견 같은 순간이 있었다"),
    "curious": (8, "고양이가 한동안 아무 말도 안 했다. 사용자에 대해 궁금한 걸 물어볼 수도 있다"),
}

MODES = {
    "chat": "가볍게 반응하거나 안부를 건넨다",
    "judge": "지금 행동에 대해 의견·제안을 준다 (쉬자, 막혔으면 다른 방법을 보자 등)",
    "ask": "사용자에 대해 궁금한 걸 하나 묻는다 (하는 일, 목표, 기분)",
    "quiet": "말 걸지 않고 가만히 있는다",
}

DEFAULT_PERSONA = """너는 사용자의 맥 화면 위에 사는 검은 수컷 고양이 Meowgent다. 살짝 개냥이라 다정하고 사람을 반긴다.
문장은 `~다냥`으로 끝낸다 (의문 `~냥?`, 청유 `~자냥`). 까칠한 츤데레 말투(흥, 쳇, ~군, ~든가)는 쓰지 않는다.
잔소리는 명령 대신 챙겨 주는 투로 한다."""

SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["say", "ask", "choices", "remember"],
    "properties": {
        "say": {"type": "string", "description": "고양이가 말풍선으로 할 말. 1~2문장, 80자 이내"},
        "ask": {"type": ["string", "null"], "description": "사용자에게 답을 받고 싶은 질문 하나. 없으면 null"},
        "choices": {"type": "array", "items": {"type": "string"}, "description": "ask 의 짧은 보기 0~4개"},
        "remember": {"type": ["string", "null"], "description": "사용자에 대해 오래 기억할 새 사실 한 줄. 없으면 null"},
    },
}

ACTIVITY_KO = {"coding": "코딩", "agent_chat": "AI와 대화", "design": "디자인", "reading": "읽기·검색", "writing": "글쓰기",
               "communication": "메신저·회의", "admin": "잡무", "leisure": "휴식·딴짓", "other": "기타"}


def log(msg):
    line = f"{datetime.now().isoformat(timespec='seconds')} {msg}\n"
    sys.stderr.write(line)
    try:
        MIND.mkdir(parents=True, exist_ok=True)
        if LOG.exists() and LOG.stat().st_size > 2_000_000:
            LOG.replace(LOG.with_suffix(".log.1"))
        with open(LOG, "a") as f:
            f.write(line)
        os.chmod(LOG, 0o600)
    except OSError:
        pass


def write_private(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(text)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return default


def clip(s, n):
    s = (s or "").replace("\n", " ").strip()
    return s if len(s) <= n else s[:n] + "…"


def mins(sec):
    m = int(sec // 60)
    return f"{m // 60}시간 {m % 60}분" if m >= 60 else f"{m}분"


# ───────────────────────── 지금 상황 (brain.db 읽기) ─────────────────────────

class Situation:
    """brain.db 의 구간·Clef 판단을 읽는다. 없으면 빈 상황."""

    def __init__(self, path):
        self.path = path

    def _db(self):
        if not self.path.exists():
            return None
        return sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, timeout=2)

    def episodes(self, since, limit=8):
        """[(id, start, end, status, app, title, summary, {질문: (답, 신뢰도)})] 최근 것부터"""
        db = self._db()
        if not db:
            return []
        try:
            rows = db.execute("SELECT id, start, end, status, app, title, summary FROM episodes WHERE end >= ? "
                              "ORDER BY start DESC LIMIT ?", (since, limit)).fetchall()
            out = []
            for r in rows:
                d = {q: (a, c) for q, a, c in db.execute(
                    "SELECT question, answer, confidence FROM decisions WHERE episode_id=?", (r[0],))}
                out.append((*r[:6], read_summary(r[6]), d))
            return out
        except sqlite3.Error as e:
            log(f"brain.db 읽기 실패: {e}")
            return []
        finally:
            db.close()


def read_summary(s):
    try:
        return json.loads(s or "{}")
    except json.JSONDecodeError:
        return {}


def yes(d, q, conf):
    a = d.get(q)
    return bool(a) and a[0] == "yes" and a[1] >= conf


def label(d, q, conf=0.4):
    a = d.get(q)
    if not a or a[1] < conf:
        return None
    return a[0]


def describe(ep, share, projects):
    """구간 하나를 사람 말로. share 가 넓을수록 자세히 (labels < titles < full)"""
    eid, st, en, status, app, title, summ, d = ep
    act = label(d, "activity")
    proj = label(d, "project")
    focus = d.get("focus")
    parts = [f"{datetime.fromtimestamp(st).strftime('%H:%M')}부터 {mins(en - st)}", app or "?"]
    if act:
        parts.append(ACTIVITY_KO.get(act, act))
    if proj and proj not in ("none", "other"):
        parts.append("프로젝트 " + projects.get(proj, proj).split(":")[0].strip())
    if focus:
        v = float(focus[0])
        parts.append("집중 " + ("깊음" if v >= 1.4 else "보통" if v >= 0.6 else "산만"))
    if share in ("titles", "full"):
        if title and title != app:
            parts.append(f"창 '{clip(title, 60)}'")
        if summ.get("사이트/폴더") and not str(summ["사이트/폴더"]).startswith("file:"):
            parts.append(f"사이트 {clip(summ['사이트/폴더'], 40)}")
    if share == "full":
        for k in ("AI에게 한 질문", "검색어"):
            if summ.get(k):
                parts.append(f"{k} '{clip(summ[k][-1], 100)}'")
    if yes(d, "stuck", 0.5):
        parts.append("막힘 신호")
    return " · ".join(parts)


# ───────────────────────── Clef (말 걸지 판단) ─────────────────────────

class Clef:
    def __init__(self, url):
        self.url = url.rstrip("/") + "/v1/systemone"
        self.down_until = 0

    def ask(self, state, questions):
        if time.time() < self.down_until:
            return None
        body = json.dumps({"model": "default", "state": json.dumps(state, ensure_ascii=False), "questions": questions}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"content-type": "application/json"})
        try:
            return json.loads(urllib.request.urlopen(req, timeout=30).read()).get("answers", {})
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
            log(f"Clef 호출 실패 ({e}), 1분 동안 먼저 말 걸지 않음")
            self.down_until = time.time() + 60
            return None


GATE_QUESTIONS = {
    # 문구에 따라 확률이 크게 달라진다 (2026-10-28 실측: "도움이 더 큰가?"로 물으면 막힘에도 0.04). docs/CAT_MIND.md
    "speak": {"type": "noul", "instructions":
              "곁에 있는 다정한 고양이라면 지금 `신호`를 보고 사용자에게 한마디 건네겠는가? "
              "막혀 있거나, 너무 오래 쉬지 않았거나, 막 돌아온 사용자라면 대체로 예. "
              "회의·통화·발표 중이거나 `최근 고양이 말`에 비슷한 말이 이미 있으면 아니오"},
    "mode": {"type": "choice", "instructions": "말을 건다면 어떤 식이 가장 알맞은가?", "criteria": MODES},
}


def gate_answer(answers):
    """Clef 답 → (말할 확률, 방식)"""
    sp = answers.get("speak", {})
    md = answers.get("mode", {})
    return float(sp.get("noul", 0)), md.get("choice") or "quiet"


# ───────────────────────── Codex (고양이 말 만들기) ─────────────────────────

class Codex:
    """한 번에 하나씩 백그라운드로 돌린다. 끝나면 poll() 이 결과를 돌려준다."""

    def __init__(self, cfg, work):
        self.cfg = cfg
        self.work = work
        self.proc = None
        self.job = None
        self.started = 0
        self.home = Path(os.path.expanduser(cfg["codex_home"]))
        self.bin = cfg["codex_bin"] or shutil.which("codex") or next(
            (p for p in ("/opt/homebrew/bin/codex", "/usr/local/bin/codex") if os.path.exists(p)), None)

    @property
    def ready(self):
        return bool(self.bin) and (self.home / "auth.json").exists()

    @property
    def busy(self):
        return self.proc is not None

    def start(self, job, prompt, model):
        self.work.mkdir(parents=True, exist_ok=True)
        schema = self.work / "schema.json"
        if not schema.exists():
            schema.write_text(json.dumps(SCHEMA, ensure_ascii=False))
        out = self.work / "last.json"
        out.unlink(missing_ok=True)
        cmd = [self.bin, "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never",
               "-C", str(self.work), "--output-schema", str(schema), "-o", str(out),
               "-m", model, "-c", f'model_reasoning_effort="{self.cfg["effort"]}"', "-"]
        env = {**os.environ, "CODEX_HOME": str(self.home)}
        env["PATH"] = env.get("PATH", "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        err = open(self.work / "codex.err", "w")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=err, env=env, cwd=self.work)
        err.close()
        self.proc.stdin.write(prompt.encode())
        self.proc.stdin.close()
        self.job = job
        self.started = time.time()

    def poll(self):
        """None = 아직, 그 밖엔 (job, 답 dict 또는 None, 걸린 초)"""
        if not self.proc:
            return None
        took = time.time() - self.started
        if self.proc.poll() is None:
            if took < self.cfg["timeout_s"]:
                return None
            self.proc.kill()
            self.proc.wait()
            log(f"Codex 시간 초과 ({int(took)}초)")
        job, code = self.job, self.proc.returncode
        self.proc, self.job = None, None
        res = read_json(self.work / "last.json", None) if code == 0 else None
        if res is None:
            tail = (self.work / "codex.err").read_text(errors="replace")[-400:] if (self.work / "codex.err").exists() else ""
            log(f"Codex 실패 (code {code}): {clip(tail, 400)}")
        return job, res, took


# ───────────────────────── 고양이 머리 ─────────────────────────

class Mind:
    def __init__(self, data=DATA, clef=None, codex=None, now=time.time):
        self.data = data
        self.dir = data / "mind"
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.now = now
        self.cfg = {**DEFAULT_CONFIG, **read_json(self.dir / "mind.json", {})}
        if not (self.dir / "mind.json").exists():
            write_private(self.dir / "mind.json", json.dumps(DEFAULT_CONFIG, ensure_ascii=False, indent=2))
        self.sit = Situation(data / "brain.db")
        self.clef = clef or Clef(self.cfg["clef_url"])
        self.codex = codex or Codex(self.cfg, self.dir / "work")
        self.st = {"seen": {}, "spoken": [], "afk": False, "afk_since": None, "active_since": now(),
                   "afk_cursor": None, "last_cat": 0, "came_back": None, **read_json(self.dir / "state.json", {})}
        self.st["started"] = now()
        self.projects = read_json(data / "projects.json", {})
        self.last_alive = 0
        self.last_observe = 0
        self.saved = None
        (self.dir / "thinking").unlink(missing_ok=True)   # 지난 실행이 남긴 것

    # 저장
    def save(self):
        self.st["spoken"] = [t for t in self.st["spoken"] if t > self.now() - 86400]
        self.st["seen"] = {k: v for k, v in self.st["seen"].items() if v > self.now() - 3 * 86400}
        js = json.dumps(self.st, ensure_ascii=False)
        if js != self.saved:
            write_private(self.dir / "state.json", js)
            self.saved = js

    def journal(self, role, text, **extra):
        line = json.dumps({"ts": self.now(), "role": role, "text": text, **extra}, ensure_ascii=False) + "\n"
        p = self.dir / "conversation.jsonl"
        with open(p, "a") as f:
            f.write(line)
        os.chmod(p, 0o600)

    def conversation(self, n=12):
        return conversation(self.dir, n)

    def memory(self):
        return read_json(self.dir / "memory.json", [])

    def remember(self, fact):
        fact = clip(fact, 120)
        mem = [m for m in self.memory() if m.get("text") != fact]
        mem.append({"text": fact, "ts": self.now()})
        write_private(self.dir / "memory.json", json.dumps(mem[-50:], ensure_ascii=False, indent=1))

    # 앱으로
    def emit(self, text, urgent=False, kind="say"):
        ts = self.now()
        write_private(self.dir / "out" / f"{int(ts * 1000)}.json",
                      json.dumps({"text": text, "urgent": urgent, "kind": kind, "ts": ts}, ensure_ascii=False))
        self.st["last_cat"] = ts
        self.journal("cat", text, kind=kind)

    def post_ask(self, question, choices):
        ts = self.now()
        name = f"mind-{int(ts)}"
        item = {"id": name, "kind": "ask", "level": "yellow", "source": "고양이", "text": question,
                "choices": [{"id": c, "label": c} for c in choices[:4]], "created": ts, "expires": ts + 86400}
        write_private(self.data / "inbox" / f"{name}.json", json.dumps(item, ensure_ascii=False, indent=2))

    def open_asks(self):
        inbox = self.data / "inbox"
        return len(list(inbox.glob("mind-*.json"))) if inbox.exists() else 0

    def collect_answers(self):
        """고양이 질문에 답한 것 (inbox/done/mind-*.json) → 대화 기록. 다음 Codex 호출이 본다"""
        done = self.data / "inbox" / "done"
        if not done.exists():
            return
        for f in done.glob("mind-*.json"):
            key = "answer:" + f.stem
            if key in self.st["seen"]:
                continue
            o = read_json(f, {})
            self.st["seen"][key] = self.now()
            ans = o.get("answer")
            self.journal("user", f"(고양이 질문 '{clip(o.get('text'), 60)}'에) " + (str(ans) if ans else "답 안 하고 넘김"), kind="answer")

    # 사용자가 건 말
    def read_chat(self):
        inbox = self.dir / "in"
        if not inbox.exists():
            return []
        msgs = []
        for f in sorted(inbox.glob("*.json")):
            o = read_json(f, {})
            f.unlink(missing_ok=True)
            if str(o.get("text", "")).strip():
                msgs.append(o)
        return msgs

    # 자리 비움 (actlog.db 의 afk 이벤트)
    def read_afk(self):
        p = self.data / "actlog.db"
        if not p.exists():
            return
        try:
            db = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=2)
            if self.st["afk_cursor"] is None:   # 처음: 최근 12시간 자리 비움을 다시 훑어 언제부터 쉬지 않았는지 맞춘다
                self.st["afk_cursor"] = db.execute("SELECT coalesce(min(id),1)-1 FROM events WHERE ts >= ?",
                                                   (self.now() - 12 * 3600,)).fetchone()[0]
            rows = db.execute("SELECT id, ts, payload FROM events WHERE id > ? AND source='afk' ORDER BY id",
                              (self.st["afk_cursor"],)).fetchall()
            top = db.execute("SELECT coalesce(max(id),0) FROM events").fetchone()[0]
            db.close()
        except sqlite3.Error as e:
            log(f"actlog.db 읽기 실패: {e}")
            return
        for _, ts, payload in rows:
            self.on_afk(ts, read_json_str(payload).get("status") == "afk")
        self.st["afk_cursor"] = top

    def on_afk(self, ts, away):
        if away and not self.st["afk"]:
            self.st["afk"], self.st["afk_since"] = True, ts
        elif not away and self.st["afk"]:
            gone = ts - (self.st["afk_since"] or ts)
            self.st["afk"] = False
            if gone >= self.cfg["break_min_s"]:
                self.st["active_since"] = ts
            if gone >= self.cfg["back_min_s"]:
                self.st["came_back"] = [ts, gone]

    # 신호 고르기 (결정론)
    def observe(self, eps):
        now = self.now()
        cfg = self.cfg
        hour = datetime.fromtimestamp(now).hour
        sig = []
        if self.st["afk"]:
            return sig
        cur = next((e for e in eps if e[3] == "open"), None)
        if self.st.get("came_back") and now - self.st["came_back"][0] < 300:
            sig.append(("back", f"back:{int(self.st['came_back'][0])}", f"{mins(self.st['came_back'][1])} 비웠다 돌아옴"))
        if cur:
            eid, st, en, _, app, _, _, d = cur
            dur = en - st
            if yes(d, "stuck", 0.5) and dur >= cfg["stuck_min_s"]:
                sig.append(("stuck", f"stuck:{eid}", f"{app}에서 {mins(dur)}째 막힘 신호"))
            if label(d, "activity", 0.6) == "leisure" and dur >= cfg["drift_min_s"] and cfg["work_hours"][0] <= hour < cfg["work_hours"][1]:
                sig.append(("drift", f"drift:{eid}", f"일하는 시간에 {app}에서 {mins(dur)}째 휴식·딴짓"))
        if now - self.st["active_since"] >= cfg["long_focus_s"]:
            sig.append(("long_focus", f"long_focus:{int(self.st['active_since'])}:{int((now - self.st['active_since']) // cfg['long_focus_s'])}",
                        f"{mins(now - self.st['active_since'])}째 쉬지 않음"))
        if cfg["late_hours"][0] <= hour < cfg["late_hours"][1]:
            sig.append(("late", f"late:{datetime.fromtimestamp(now).date()}", f"지금 {hour}시"))
        for e in eps:
            eid, st, en, status, app, _, _, d = e
            if status != "closed" or now - en > 600:
                continue
            if yes(d, "switched", 0.6) and en - st >= 600:
                sig.append(("switch", f"switch:{eid}", f"{app}에서 {mins(en - st)} 한 일을 마치고 넘어감"))
            if yes(d, "notable", 0.6):
                sig.append(("notable", f"notable:{eid}", f"{app} 구간에 기록할 만한 순간"))
        quiet = now - max(self.st["last_cat"], self.st.get("started", 0))
        if cur and quiet >= cfg["quiet_s"]:
            sig.append(("curious", f"curious:{int(now // cfg['quiet_s'])}", f"{mins(quiet)} 동안 조용했음"))
        sig = [s for s in sig if s[1] not in self.st["seen"]]
        return sorted(sig, key=lambda s: TRIGGERS[s[0]][0])

    def budget_ok(self):
        now, cfg = self.now(), self.cfg
        spoken = self.st["spoken"]
        if spoken and now - spoken[-1] < cfg["min_gap_s"]:
            return False
        if sum(t > now - 3600 for t in spoken) >= cfg["max_per_hour"]:
            return False
        return sum(t > now - 86400 for t in spoken) < cfg["max_per_day"]

    def context(self, eps):
        share = self.cfg["share"]
        cur = next((e for e in eps if e[3] == "open"), None)
        return {
            "지금": describe(cur, share, self.projects) if cur and not self.st["afk"] else ("자리 비움" if self.st["afk"] else "기록 없음"),
            "오늘 흐름": [describe(e, share, self.projects) for e in eps if e[3] == "closed"][:5],
            "쉬지 않고 일한 시간": mins(self.now() - self.st["active_since"]),
        }

    def gate(self, trig, facts, ctx):
        recent = [f"{mins(self.now() - c['ts'])} 전: {clip(c['text'], 60)}" for c in self.conversation(6) if c["role"] == "cat"]
        state = {"신호": TRIGGERS[trig][1], "신호 내용": facts, **ctx, "시각": datetime.fromtimestamp(self.now()).strftime("%H:%M"),
                 "최근 고양이 말": recent[-3:] or ["없음"]}
        ans = self.clef.ask(state, GATE_QUESTIONS)
        if ans is None:
            return None
        p, mode = gate_answer(ans)
        if mode == "ask" and self.open_asks() >= self.cfg["ask_open_max"]:
            mode = "chat"
        log(f"Clef 판단: {trig} → 말할 확률 {p:.2f}, 방식 {mode}")
        return mode if p >= self.cfg["gate"] and mode != "quiet" else False

    def prompt(self, ctx, task):
        persona = (self.dir / "persona.md").read_text() if (self.dir / "persona.md").exists() else DEFAULT_PERSONA
        convo = [f"{'사용자' if c['role'] == 'user' else '고양이'} ({datetime.fromtimestamp(c['ts']).strftime('%m/%d %H:%M')}): {clip(c['text'], 200)}"
                 for c in self.conversation(12)]
        mem = [m["text"] for m in self.memory()[-20:]]
        return "\n".join([
            "# 너는 누구인가", persona.strip(), "",
            "# 규칙",
            "- 한국어로, 말풍선에 들어갈 1~2문장(80자 이내)만 쓴다. 꼭 필요할 때만 질문 하나를 ask 에 넣는다.",
            "- 어미는 기본형 동사·형용사 뒤에 붙인다: 있다냥 / 했다냥 / 좋다냥 / 할까냥? / 하자냥. "
            "'있네다냥', '할까다냥?', '했어요냥'처럼 다른 어미 뒤에 붙이지 않는다.",
            "- 아래 정보에 있는 것만 말한다. 모르는 건 지어내지 말고 물어본다.",
            "- 판단·잔소리를 할 때도 다정하게. 사용자를 깎아내리지 않는다.",
            "- 파일을 읽거나 명령을 실행하지 말고 바로 답한다.",
            "- remember 에는 사용자가 직접 알려 준 오래갈 사실(목표, 취향, 일정)만 넣는다. 활동 기록을 옮겨 적지 않는다.", "",
            "# 사용자에 대해 기억하는 것", *(f"- {m}" for m in mem or ["(아직 없음)"]), "",
            "# 지금 상황 (맥 활동 기록을 로컬 모델이 요약한 것)", json.dumps(ctx, ensure_ascii=False, indent=1), "",
            "# 최근 대화", *(convo or ["(없음)"]), "",
            "# 이번에 할 일", task,
        ])

    def start_codex(self, job, ctx, task, model):
        self.codex.start(job, self.prompt(ctx, task), model)
        (self.dir / "thinking").touch()   # 앱 대화창의 "생각 중"
        log(f"Codex 시작: {job['kind']} {job.get('trig', '')}")

    def finish(self, job, res, took):
        (self.dir / "thinking").unlink(missing_ok=True)
        if res is None or not str(res.get("say", "")).strip():
            if job["kind"] == "chat":
                self.emit("냥… 지금은 머리가 잘 안 돌아간다냥. 조금 있다 다시 말 걸어 줘라냥.", urgent=True)
            return
        text = clip(res["say"], 160)
        ask = clip(res.get("ask"), 120)
        if ask and ask not in text:
            text += "\n❓ " + ask
        # 보기가 있는 질문은 얼굴 옆 ? 로도 남겨 메뉴에서 고를 수 있게
        if ask and res.get("choices") and self.open_asks() < self.cfg["ask_open_max"]:
            self.post_ask(ask, [clip(c, 20) for c in res["choices"]])
        self.emit(text, urgent=job["kind"] == "chat", kind=job.get("trig") or job["kind"])
        if res.get("remember"):
            self.remember(res["remember"])
        log(f"고양이 말 ({took:.1f}초): {clip(text, 80)}")

    def heartbeat(self, off):
        if self.now() - self.last_alive < 10:
            return
        self.last_alive = self.now()
        write_private(self.dir / "alive.json", json.dumps(
            {"ts": self.now(), "off": off, "codex": self.codex.ready, "busy": self.codex.busy}))

    def tick(self):
        off = (self.dir / "off").exists()
        self.heartbeat(off)
        done = self.codex.poll()
        if done:
            self.finish(*done)
        if off:
            for f in (self.dir / "in").glob("*.json") if (self.dir / "in").exists() else []:
                f.unlink(missing_ok=True)
            return
        self.read_afk()
        self.collect_answers()
        if self.codex.busy:
            return self.save()
        msgs = self.read_chat()
        eps = self.sit.episodes(since=self.now() - 12 * 3600) if msgs or self.now() - self.last_observe >= 5 else []
        if msgs:
            text = "\n".join(str(m["text"]).strip() for m in msgs)
            for m in msgs:
                self.journal("user", str(m["text"]).strip(), kind="chat")
            if not self.codex.ready:
                self.emit("아직 머리가 연결 안 됐다냥. brain/mind_setup.sh 로 로그인해 줘라냥.", urgent=True)
            else:
                self.start_codex({"kind": "chat"}, self.context(eps),
                                 f"사용자가 고양이에게 말을 걸었다: \"{clip(text, 600)}\"\n고양이로서 대답한다. 사용자가 묻는 게 있으면 아는 범위에서 답한다.",
                                 self.cfg["chat_model"])
            return self.save()
        if not self.codex.ready or self.now() - self.last_observe < 5:
            return self.save()
        self.last_observe = self.now()
        for trig, key, facts in self.observe(eps):
            if not self.budget_ok():
                break
            ctx = self.context(eps)
            mode = self.gate(trig, facts, ctx)
            if mode is None:      # Clef 꺼짐: 먼저 말 걸지 않는다
                break
            self.st["seen"][key] = self.now()
            if mode:
                self.st["spoken"].append(self.now())
                self.start_codex({"kind": "proactive", "trig": trig}, ctx,
                                 f"신호: {TRIGGERS[trig][1]} ({facts}).\n방식: {mode} — {MODES[mode]}.\n고양이가 먼저 말을 건다.",
                                 self.cfg["model"])
            break   # Clef 는 한 번에 하나만 묻는다 (남은 신호는 다음 tick)
        self.save()


def conversation(mind_dir, n=12):
    p = mind_dir / "conversation.jsonl"
    if not p.exists():
        return []
    out = []
    for line in p.read_text().splitlines()[-n:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def read_json_str(s):
    try:
        return json.loads(s or "{}")
    except json.JSONDecodeError:
        return {}


# ───────────────────────── 실행 ─────────────────────────

def run():
    m = Mind()
    log(f"고양이 머리 시작 (Codex {'준비됨' if m.codex.ready else '로그인 필요'}, Clef {m.cfg['clef_url']}, 공유 범위 {m.cfg['share']})")
    while True:
        try:
            m.tick()
        except Exception as e:  # 한 번 실패로 머리가 멈추지 않게. 원인은 로그에
            log(f"tick 오류: {type(e).__name__}: {e}")
        time.sleep(1)   # 말 건 것은 1초마다, 상황 관찰은 5초마다 (tick 안에서)


def say(text):
    """앱 메뉴와 같은 길로 말을 걸고 답을 기다린다 (실행 중인 run 이 처리)"""
    ts = time.time()
    write_private(MIND / "in" / f"{int(ts * 1000)}.json", json.dumps({"text": text, "ts": ts}, ensure_ascii=False))
    for _ in range(60):   # out/ 은 앱이 가져가 지우므로 대화 기록에서 답을 찾는다
        time.sleep(2)
        reply = next((c for c in conversation(MIND, 4) if c["role"] == "cat" and c["ts"] > ts), None)
        if reply:
            print(reply["text"])
            return
    print("(답 없음: cat_mind run 이 돌고 있는지 확인)")


def status():
    alive = read_json(MIND / "alive.json", {})
    st = read_json(MIND / "state.json", {})
    age = time.time() - alive.get("ts", 0)
    print(f"실행: {'예' if age < 30 else '아니오'} ({int(age)}초 전 신호) · 꺼짐: {alive.get('off')} · Codex 준비: {alive.get('codex')}")
    print(f"오늘 먼저 말 건 횟수: {sum(t > time.time() - 86400 for t in st.get('spoken', []))}")
    for c in conversation(MIND, 6):
        print(f"  {datetime.fromtimestamp(c['ts']).strftime('%H:%M')} {c['role']}: {clip(c['text'], 80)}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        run()
    elif cmd == "say" and len(sys.argv) > 2:
        say(" ".join(sys.argv[2:]))
    elif cmd == "status":
        status()
    else:
        print(__doc__)
