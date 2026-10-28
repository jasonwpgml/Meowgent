#!/usr/bin/env python3
"""ActLog 2단계: 원본 이벤트 → 작업 구간(에피소드) → Clef 실시간 판단 → now.md / 오늘 타임라인.

  python3 actlog_brain.py run        # 계속 실행 (launchd가 띄움)
  python3 actlog_brain.py once       # 지금까지 쌓인 것만 처리하고 종료
  python3 actlog_brain.py status     # 상태 요약

표준 라이브러리만 쓴다. ActLog DB는 읽기 전용으로 열고, 판단 결과는 brain.db에 따로 쓴다.
"""
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import unquote, urlsplit

DATA = Path.home() / "Library/Application Support/ActLog"
EVENTS_DB = DATA / "actlog.db"
BRAIN_DB = DATA / "brain.db"
CONFIG = DATA / "brain.json"
PROJECTS = DATA / "projects.json"
LOG = DATA / "brain.log"
INBOX = DATA / "inbox"    # 고양이 얼굴 옆 ! · ? 항목 (docs/INBOX.md)

QSET = "v1"

DEFAULT_CONFIG = {
    "clef_url": "http://localhost:8010",
    "wiki_dir": str(DATA / "wiki"),
    "switch_min_s": 20,      # 다른 앱/사이트로 이만큼 넘어가 있어야 새 구간 (Cmd-Tab 왔다갔다 흡수)
    "max_episode_s": 1800,   # 한 구간 최대 길이
    "rolling_s": 60,         # 진행 중인 구간을 다시 판단하는 간격
    "accept": 0.7,           # 이 이상이면 확정
    "guess": 0.4,            # 이 이상이면 추정, 미만이면 미분류
    "ask_min_s": 600,        # 이보다 긴 구간인데 프로젝트를 모르면 고양이가 물어본다 (노란 ?)
    "ask_open_max": 5,       # 안 답한 질문이 이만큼 쌓이면 더 묻지 않는다
}

# 처음 실행 때 projects.json 으로 쓰는 초기 목록. 이후엔 그 파일을 고쳐서 관리.
DEFAULT_PROJECTS = {
    "lecture": "강의 교안·발표자료 만들기: 교안 HTML 페이지 수정, 시안, 시각화, 실습 자료 (예시 — projects.json 에서 내 프로젝트로 바꿀 것)",
    "work": "회사 업무 중 위에 안 잡히는 것: 사이트, 상품, 운영 (예시)",
    "meowgent": "Meowgent 만들기: 내 행동을 기록하는 수집기, Clef 판단, LLM 위키, 로컬 모델, 권한·인증서 같은 이야기를 코딩 에이전트와 나누는 작업",
    "job": "취업·이직 준비: 채용 공고 보기, 이력서, 포트폴리오, 자기소개서",
    "side_project": "개인 사이드 프로젝트 (~/dev/projects/<이름>) (예시)",
    "tool_research": "웹에서 새 AI 도구·서비스를 검색하고 평판·요금·대안을 비교 (예: Aside, Cursor 요금제). AI 앱을 일하는 데 쓰는 것 자체는 해당 안 됨",
}

ACTIVITY = {
    "coding": "코드 작성·수정·디버깅 (에디터, 터미널, 코딩 에이전트에게 코드 작업 지시)",
    "agent_chat": "AI 에이전트·챗봇과 대화하며 생각 정리, 질문, 기획 (코드 작업 지시가 아닌 것)",
    "design": "화면·시각 자료·교안 디자인을 만들거나 다듬기, 시안 검토",
    "reading": "문서·웹페이지·자료 읽기, 조사, 검색",
    "writing": "문서·글·기획서 작성",
    "communication": "메신저, 메일, 회의",
    "admin": "설정, 파일 정리, 계정·결제 같은 잡무",
    "leisure": "휴식, 영상, 쇼핑, 엔터테인먼트",
    "other": "위 어디에도 맞지 않음",
}

BROWSERS = {
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
    "com.brave.Browser", "com.microsoft.edgemac", "com.naver.Whale", "com.vivaldi.Vivaldi",
    "org.chromium.Chromium", "com.operasoftware.Opera", "com.apple.Safari",
}
EDITORS = {
    "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed",
    "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm",
}
# 맥락으로 치지 않는 시스템 UI (Dock 클릭, 잠금화면 등)
IGNORE_CTX = {
    "com.apple.dock", "com.apple.loginwindow", "com.jason.actlog", "com.apple.UserNotificationCenter",
    "com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.Spotlight", "com.apple.systemuiserver",
}
LOCK_BUNDLES = {"com.apple.loginwindow"}


def log(msg):
    line = f"{datetime.now().isoformat(timespec='seconds')} {msg}\n"
    sys.stderr.write(line)
    try:
        if LOG.exists() and LOG.stat().st_size > 5_000_000:
            LOG.replace(LOG.with_suffix(".log.1"))
        with open(LOG, "a") as f:
            f.write(line)
    except OSError:
        pass


def load_json(path, default):
    if path.exists():
        try:
            data = json.loads(path.read_text())
            if isinstance(default, dict) and isinstance(data, dict) and path == CONFIG:
                return {**default, **data}
            return data
        except (OSError, json.JSONDecodeError) as e:
            log(f"{path.name} 읽기 실패, 기본값 사용: {e}")
            return default
    path.write_text(json.dumps(default, ensure_ascii=False, indent=2))
    return default


def write_atomic(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


# ───────────────────────── 맥락 (어느 앱의 어느 일인가) ─────────────────────────

def url_context(url):
    """브라우저 맥락 = 사이트. 내 컴퓨터 파일이면 폴더, 로컬 서버면 포트까지."""
    if not url:
        return None
    try:
        u = urlsplit(url)
    except ValueError:
        return None
    if u.scheme == "file":
        parts = [p for p in unquote(u.path).split("/") if p]
        return "file:/" + "/".join(parts[:6])
    if u.hostname in ("127.0.0.1", "localhost"):
        return f"local:{u.port}"
    if u.scheme in ("http", "https") and u.hostname:
        host = u.hostname.lower()
        return host[4:] if host.startswith("www.") else host
    return u.scheme or None


def window_context(bundle, window):
    """에디터는 창 제목의 프로젝트 부분 ("file.py — repo")."""
    if bundle in EDITORS and window:
        parts = re.split(r" [—–-] ", window)
        return parts[-1].strip() if len(parts) > 1 else window.strip()
    return None


def bucket(n, steps):
    """숫자를 이름으로 (결정 모델은 숫자 비교에 약하다)."""
    for limit, name in steps:
        if n <= limit:
            return name
    return steps[-1][1]


def fmt_dur(sec):
    m = int(sec // 60)
    return f"{m // 60}시간 {m % 60}분" if m >= 60 else f"{m}분"


def clip(s, n):
    s = (s or "").replace("\n", " ").strip()
    return s if len(s) <= n else s[:n] + "…"


# ───────────────────────── 에피소드 ─────────────────────────

class Segment:
    """같은 맥락이 이어지는 구간. 에피소드 후보이자 에피소드 본체."""

    def __init__(self, ctx, app, bundle, start):
        self.ctx = ctx            # (bundle, 세부맥락)
        self.app = app
        self.bundle = bundle
        self.start = start
        self.end = start
        self.first_id = None
        self.last_id = None
        self.titles = Counter()
        self.last_title = None
        self.urls = []
        self.searches = []
        self.texts = []           # (ts, text, kind, ai)
        self.ai_answers = []      # (ai, chars, head)
        self.clicks = Counter()
        self.pastes = []
        self.keys = 0
        self.click_count = 0
        self.scrolls = 0
        self.brief = []           # 잠깐 들른 곳 [(app, 초)]
        self.switches = 0
        self.row = None           # brain.db 의 episodes.id

    def add(self, ev):
        eid, ts, source, app, bundle, window, url, p = ev
        self.end = max(self.end, ts)
        self.first_id = self.first_id or eid
        self.last_id = eid
        if window and source in ("window", "browser", "text", "click"):
            self.titles[window] += 1
            self.last_title = window
        if url and source == "browser" and (not self.urls or self.urls[-1][0] != url):
            self.urls.append((url, p.get("title") or window or ""))
        if source == "search":
            self.searches.append(p.get("query", ""))
        elif source == "text" and p.get("text"):
            self.texts.append((ts, p["text"], p.get("kind"), p.get("ai")))
        elif source == "ai_response":
            self.ai_answers.append((p.get("ai"), p.get("chars", 0), clip(p.get("text"), 160)))
        elif source == "click":
            if p.get("label"):
                self.clicks[f"{p.get('role', '').replace('AX', '')} '{clip(p['label'], 40)}'"] += 1
        elif source == "paste" and p.get("text"):
            self.pastes.append(clip(p["text"], 120))
        elif source == "activity":
            self.keys += p.get("keys", 0)
            self.click_count += p.get("clicks", 0)
            self.scrolls += p.get("scrolls", 0)

    def absorb(self, other):
        """잠깐 들렀다 돌아온 구간을 흡수 (내용은 합치고 '잠깐 들른 곳'으로 표시)."""
        self.brief.append((other.app, int(other.end - other.start) or 1))
        self.switches += 1
        self.end = max(self.end, other.end)
        self.last_id = other.last_id or self.last_id
        self.searches += other.searches
        self.texts += other.texts
        self.ai_answers += other.ai_answers
        self.clicks.update(other.clicks)
        self.pastes += other.pastes
        self.keys += other.keys
        self.click_count += other.click_count
        self.scrolls += other.scrolls

    @property
    def duration(self):
        return max(0.0, self.end - self.start)

    def has_content(self):
        return bool(self.texts or self.searches or self.clicks or self.urls or self.keys or self.ai_answers)

    def state(self, previous=None):
        """Clef에 넣는 압축 요약. 작게, 이름 붙인 값으로."""
        dur = self.duration
        t0 = datetime.fromtimestamp(self.start).strftime("%H:%M")
        t1 = datetime.fromtimestamp(self.end).strftime("%H:%M")
        typed_chars = sum(len(t[1]) for t in self.texts if t[2] != "ai_prompt")
        prompts = [t for t in self.texts if t[2] == "ai_prompt"]
        others = [t for t in self.texts if t[2] != "ai_prompt"]
        pages = []
        for url, title in self.urls[-6:]:
            if title and title not in pages:
                pages.append(clip(title, 80))
        st = {
            "시간": f"{t0}-{t1} ({fmt_dur(dur)})",
            "앱": self.app,
            "창 제목": clip(self.last_title or (self.titles.most_common(1)[0][0] if self.titles else ""), 120),
        }
        ctx = self.ctx[1]
        if ctx:
            st["사이트/폴더"] = clip(ctx, 100)
        if len(pages) > 1:
            st["본 페이지들"] = pages[-5:]
        if self.searches:
            st["검색어"] = list(dict.fromkeys(self.searches))[-4:]
        if prompts:
            st["AI에게 한 질문"] = [clip(t[1], 200) for t in prompts[-3:]]
            st["질문한 AI"] = prompts[-1][3]
        if self.ai_answers:
            st["AI 답변 앞부분"] = [a[2] for a in self.ai_answers[-2:]]
        if others:
            st["입력한 글"] = {"양": bucket(typed_chars, [(0, "없음"), (80, "조금"), (600, "보통"), (10**9, "많음")]),
                           "예시": [clip(t[1], 150) for t in others[-3:]]}
        if self.pastes:
            st["붙여넣은 내용"] = self.pastes[-2:]
        if self.clicks:
            st["누른 것"] = [c for c, _ in self.clicks.most_common(8)]
        per_min = (self.keys + self.click_count) / max(dur / 60, 1)
        st["활동량"] = bucket(per_min, [(2, "거의 없음 (보기만 함)"), (20, "낮음"), (80, "보통"), (10**9, "높음")])
        if self.brief:
            st["잠깐 들른 곳"] = [f"{a} {s}초" for a, s in self.brief[-5:]]
            st["전환"] = bucket(len(self.brief), [(1, "적음"), (4, "보통"), (10**9, "잦음")])
        if previous:
            st["직전 작업"] = previous
        return st


class Segmenter:
    """이벤트를 순서대로 받아 에피소드를 열고 닫는다. 닫힌 것은 on_close로 넘긴다."""

    def __init__(self, cfg, on_close):
        self.cfg = cfg
        self.on_close = on_close
        self.ep = None        # 현재 에피소드
        self.pending = None   # 막 넘어간 다른 맥락 (아직 switch_min_s 안 됨)
        self.fg = None        # 지금 앞에 있는 맥락 (ctx, app, bundle)
        self.fg_url = {}      # 브라우저별 마지막 사이트
        self.afk = False

    def _ctx_of(self, source, app, bundle, window, url):
        if bundle in BROWSERS:
            c = url_context(url) or self.fg_url.get(bundle)
            if url:
                self.fg_url[bundle] = c
            return (bundle, c)
        return (bundle, window_context(bundle, window))

    def _close(self, at=None):
        if self.pending:
            self._resolve_pending(force=True)
        if self.ep:
            if at is not None and at < self.ep.end:   # 자리 비움은 마지막 입력 시각으로 소급된다
                self.ep.end = max(self.ep.start, at)
            self.on_close(self.ep)
            self.ep = None

    def _resolve_pending(self, force=False, now=None):
        p = self.pending
        if not p:
            return
        long_enough = (now or p.end) - p.start >= self.cfg["switch_min_s"]
        if long_enough or self.ep is None:
            if self.ep:
                self.on_close(self.ep)
            self.ep = p
            self.pending = None
        elif force:
            self.ep.absorb(p)
            self.pending = None

    def tick(self, now):
        """시간이 흘러 대기 중인 전환이 확정됐는지, 구간이 너무 길어졌는지."""
        if self.pending and now - self.pending.start >= self.cfg["switch_min_s"]:
            self._resolve_pending(now=now)
        if self.ep and self.ep.duration >= self.cfg["max_episode_s"]:
            old = self.ep
            self.on_close(old)
            self.ep = Segment(old.ctx, old.app, old.bundle, old.end)

    def feed(self, ev):
        eid, ts, source, app, bundle, window, url, p = ev
        self.tick(ts)

        # 자리 비움 / 잠금 / 잠자기 → 구간 닫기
        if source == "afk":
            if p.get("status") == "afk":
                self._close(at=ts)
                self.afk = True
            else:
                self.afk = False
            return
        if source in ("health", "lifecycle", "secure"):
            return
        if bundle in LOCK_BUNDLES and source == "app":
            self._close(at=ts)
            return

        is_ctx_event = source in ("app", "window", "browser") and bundle and bundle not in IGNORE_CTX
        if is_ctx_event:
            ctx = self._ctx_of(source, app, bundle, window, url)
            self.fg = (ctx, app, bundle)
            self.afk = False
            if self.ep is None:
                self.ep = Segment(ctx, app, bundle, ts)
            elif ctx == self.ep.ctx:
                if self.pending:   # 금방 돌아옴 → 잠깐 들른 것
                    self.ep.absorb(self.pending)
                    self.pending = None
            elif self.pending and ctx == self.pending.ctx:
                pass
            else:
                if self.pending:   # 잠깐 들렀다 또 다른 곳 → 앞의 잠깐은 흡수
                    self.ep.absorb(self.pending)
                self.pending = Segment(ctx, app, bundle, ts)
        elif self.ep is None:
            if source in ("activity",) or bundle in IGNORE_CTX or not self.fg:
                return
            # 자리 비움 뒤 같은 앱에서 다시 시작
            ctx, fapp, fbundle = self.fg
            self.ep = Segment(ctx, fapp, fbundle, ts)

        target = self.pending or self.ep
        if target is not None:
            target.add(ev)


# ───────────────────────── Clef ─────────────────────────

def questions(projects):
    proj = dict(sorted(projects.items()))  # 순서 고정 (순서도 질문의 일부)
    proj["none"] = "특정 프로젝트가 아닌 개인 용무·잡무·휴식"
    proj["other"] = "목록에 없는 새 프로젝트나 작업"
    return {
        "activity": {"type": "choice", "instructions": "이 작업 구간에서 사용자가 주로 한 활동은?", "criteria": ACTIVITY},
        "project": {"type": "choice", "instructions": "이 작업 구간은 어느 프로젝트에 속하는가? 창 제목, 사이트/폴더, 입력한 글, AI에게 한 질문을 근거로 판단. 근거가 약하면 `이 앱에서 직전에 하던 프로젝트`를 참고",
                    "criteria": proj},
        "focus": {"type": "score", "instructions": "이 구간에서 사용자의 집중도는? 잦은 전환·잠깐 들른 곳이 많으면 낮고, 한 작업을 길게 이어가면 높다",
                  "criteria": ["산만함 (자주 전환)", "보통", "깊은 집중"]},
        "switched": {"type": "noul", "instructions": "`직전 작업`과 비교해 프로젝트나 목표가 바뀌었는가? 직전 작업 정보가 없으면 아니오"},
        "notable": {"type": "noul", "instructions": "결정, 완료, 방향 전환, 중요한 발견처럼 나중에 기록해 둘 만한 순간이 있는가?"},
        "stuck": {"type": "noul", "instructions": "같은 문제를 반복해서 시도하거나 오류·문제를 검색하며 막혀 있는 모습인가?"},
    }


class Clef:
    def __init__(self, url):
        self.url = url.rstrip("/") + "/v1/systemone"
        self.down_until = 0

    def ask(self, state, qs):
        if time.time() < self.down_until:
            return None
        body = json.dumps({"model": "default", "state": json.dumps(state, ensure_ascii=False), "questions": qs}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"content-type": "application/json"})
        t = time.time()
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=60).read())
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
            log(f"Clef 호출 실패 ({e}), 30초 뒤 다시")
            self.down_until = time.time() + 30
            return None
        r["_ms"] = int((time.time() - t) * 1000)
        return r


def parse_answer(a):
    """(답, 신뢰도, 확률) — noul은 '예/아니오'로 바꾸고 신뢰도 |2p-1|."""
    t = a.get("type")
    if t == "choice":
        return a.get("choice"), a.get("confidence") or 0, a.get("probabilities")
    if t == "score":
        return round(a.get("score", 0), 2), a.get("confidence") or 0, a.get("probabilities")
    p = a.get("noul", 0.5)
    return ("yes" if p >= 0.5 else "no"), abs(2 * p - 1), {"yes": p}


# ───────────────────────── 저장소 ─────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS episodes (
  id INTEGER PRIMARY KEY, start REAL, end REAL, status TEXT,
  app TEXT, bundle TEXT, ctx TEXT, title TEXT,
  first_event INTEGER, last_event INTEGER,
  summary TEXT, summary_hash TEXT, judged_hash TEXT, judged_at REAL
);
CREATE INDEX IF NOT EXISTS episodes_start ON episodes(start);
CREATE TABLE IF NOT EXISTS decisions (
  episode_id INTEGER, qset TEXT, question TEXT, answer TEXT, confidence REAL, probs TEXT,
  ts REAL, ms INTEGER, final INTEGER,
  PRIMARY KEY (episode_id, qset, question)
);
CREATE TABLE IF NOT EXISTS labels (episode_id INTEGER, question TEXT, answer TEXT, ts REAL);
"""


class Brain:
    def __init__(self):
        self.cfg = load_json(CONFIG, DEFAULT_CONFIG)
        self.projects = load_json(PROJECTS, DEFAULT_PROJECTS)
        self.qs = questions(self.projects)
        self.clef = Clef(self.cfg["clef_url"])
        self.db = sqlite3.connect(BRAIN_DB)
        self.db.executescript(SCHEMA)
        os.chmod(BRAIN_DB, 0o600)
        self.ev = sqlite3.connect(f"file:{EVENTS_DB}?mode=ro", uri=True, timeout=5)
        self.seg = Segmenter(self.cfg, self._closed)
        self.open_row = None      # 현재 열린 에피소드의 DB id
        self.wiki = Path(os.path.expanduser(self.cfg["wiki_dir"]))
        self.dirty = True
        self.next_ask = 0

    # 상태
    def get(self, key, default=None):
        r = self.db.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        return r[0] if r else default

    def put(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", (key, str(value)))

    def _prev_line(self, before_start):
        r = self.db.execute(
            "SELECT e.id, e.app, e.start, e.end FROM episodes e WHERE e.status='closed' AND e.start < ? ORDER BY e.start DESC LIMIT 1",
            (before_start,)).fetchone()
        if not r:
            return None
        d = self.decisions(r[0])
        act = d.get("activity", (None,))[0]
        proj = d.get("project", (None,))[0]
        return f"{datetime.fromtimestamp(r[2]).strftime('%H:%M')}-{datetime.fromtimestamp(r[3]).strftime('%H:%M')} {r[1]} · {act or '?'} · {proj or '?'}"

    def _app_hint(self, seg):
        """Claude·ChatGPT 앱처럼 창 제목이 늘 같은 앱은 근거가 없다 → 같은 앱에서 2시간 안에 확실히 판단된 직전 프로젝트."""
        r = self.db.execute(
            "SELECT e.start, d.answer FROM episodes e JOIN decisions d ON d.episode_id=e.id AND d.qset=? AND d.question='project' "
            "WHERE e.bundle=? AND e.start < ? AND e.start > ? AND d.confidence >= 0.6 AND d.answer NOT IN ('none','other') "
            "ORDER BY e.start DESC LIMIT 1", (QSET, seg.bundle, seg.start, seg.start - 7200)).fetchone()
        if not r:
            return None
        return f"{datetime.fromtimestamp(r[0]).strftime('%H:%M')}에 {self.projects.get(r[1], r[1]).split(':')[0]} ({r[1]})"

    def _save(self, seg, status, row_id=None):
        state = seg.state(self._prev_line(seg.start))
        hint = self._app_hint(seg)
        if hint:
            state["이 앱에서 직전에 하던 프로젝트"] = hint
        js = json.dumps(state, ensure_ascii=False)
        h = hashlib.sha1(js.encode()).hexdigest()[:16]
        vals = (seg.start, seg.end, status, seg.app, seg.bundle, json.dumps(seg.ctx, ensure_ascii=False),
                clip(seg.last_title, 200), seg.first_id, seg.last_id, js, h)
        if row_id:
            self.db.execute("UPDATE episodes SET start=?,end=?,status=?,app=?,bundle=?,ctx=?,title=?,first_event=?,last_event=?,summary=?,summary_hash=? WHERE id=?",
                            (*vals, row_id))
            return row_id
        cur = self.db.execute("INSERT INTO episodes(start,end,status,app,bundle,ctx,title,first_event,last_event,summary,summary_hash) VALUES(?,?,?,?,?,?,?,?,?,?,?)", vals)
        return cur.lastrowid

    def _closed(self, seg):
        if seg.row is None and seg.duration < 5 and not seg.has_content():
            return   # 스쳐 간 구간
        seg.row = self._save(seg, "closed", seg.row)
        if seg.row == self.open_row:
            self.open_row = None
        self.dirty = True

    def decisions(self, ep_id):
        rows = self.db.execute("SELECT question, answer, confidence FROM decisions WHERE episode_id=? AND qset=?", (ep_id, QSET)).fetchall()
        return {q: (a, c) for q, a, c in rows}

    # 이벤트 처리
    def ingest(self, limit=5000):
        cursor = self.get("cursor")
        if cursor is None:
            # 처음 실행: 오늘 0시부터
            start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
            r = self.ev.execute("SELECT min(id) FROM events WHERE ts >= ?", (start,)).fetchone()
            cursor = (r[0] or 1) - 1
        cursor = int(cursor)
        rows = self.ev.execute(
            "SELECT id, ts, source, app, bundle, window, url, payload FROM events WHERE id > ? ORDER BY id LIMIT ?",
            (cursor, limit)).fetchall()
        for row in rows:
            try:
                p = json.loads(row[7] or "{}")
            except json.JSONDecodeError:
                p = {}
            self.seg.feed((*row[:7], p))
            cursor = row[0]
        if rows:
            self.put("cursor", cursor)
            self.dirty = True
        if len(rows) < limit:   # 밀린 걸 다 읽었을 때만 "지금" 시각으로 전환 확정
            self.seg.tick(time.time())
        # 열린 에피소드 DB 반영
        ep = self.seg.ep
        if ep and ep.has_content():
            ep.row = self._save(ep, "open", ep.row)
            self.open_row = ep.row
        self.db.commit()
        return len(rows)

    # 판단
    def judge_one(self, ep_id, final):
        r = self.db.execute("SELECT summary, summary_hash, judged_hash FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not r or r[1] == r[2]:
            return False
        state = json.loads(r[0])
        resp = self.clef.ask(state, self.qs)
        if not resp:
            return False
        now = time.time()
        for q, a in resp.get("answers", {}).items():
            ans, conf, probs = parse_answer(a)
            self.db.execute("INSERT OR REPLACE INTO decisions VALUES(?,?,?,?,?,?,?,?,?)",
                            (ep_id, QSET, q, str(ans), conf, json.dumps(probs, ensure_ascii=False), now, resp["_ms"], int(final)))
        self.db.execute("UPDATE episodes SET judged_hash=?, judged_at=? WHERE id=?", (r[1], now, ep_id))
        self.db.commit()
        self.dirty = True
        return True

    def judge_pending(self, budget=3, oldest_first=False):
        done = 0
        # 1) 진행 중인 구간: rolling_s마다
        if self.open_row:
            r = self.db.execute("SELECT judged_at, summary_hash, judged_hash FROM episodes WHERE id=?", (self.open_row,)).fetchone()
            if r and r[1] != r[2] and (r[0] is None or time.time() - r[0] >= self.cfg["rolling_s"]):
                done += self.judge_one(self.open_row, final=False)
        # 2) 닫혔는데 최종 판단이 안 된 것 (최근 것부터)
        rows = self.db.execute(
            "SELECT id FROM episodes WHERE status='closed' AND (judged_hash IS NULL OR judged_hash != summary_hash) ORDER BY start " + ("ASC" if oldest_first else "DESC") + " LIMIT ?",
            (budget,)).fetchall()
        for (eid,) in rows:
            if done >= budget:
                break
            done += self.judge_one(eid, final=True)
        return done

    # 사용자에게 묻기 (고양이 ?)
    def ask_unclear(self, now=None):
        """최근 3일 중 길었는데 프로젝트를 모르는 구간을 inbox/ 에 질문으로 놓고, 답한 것은 labels 로 가져온다.
        labels 는 나중에 판단을 고치거나 학습할 재료로 모아 두기만 한다."""
        now = now or time.time()
        if now < self.next_ask:
            return
        self.next_ask = now + 60
        done = INBOX / "done"
        for f in done.glob("brain-ep-*.json") if done.exists() else []:
            try:
                o = json.loads(f.read_text())
                eid = int(o["episode_id"])
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if o.get("answer") and not self.db.execute("SELECT 1 FROM labels WHERE episode_id=? AND question='project'", (eid,)).fetchone():
                self.db.execute("INSERT INTO labels VALUES(?,?,?,?)", (eid, "project", str(o["answer"]), o.get("resolved") or now))
        self.db.commit()
        open_asks = len(list(INBOX.glob("brain-ep-*.json"))) if INBOX.exists() else 0
        if open_asks >= self.cfg["ask_open_max"]:
            return
        rows = self.db.execute(
            "SELECT e.id, e.start, e.end, e.app, e.title, e.summary FROM episodes e "
            "JOIN decisions d ON d.episode_id=e.id AND d.qset=? AND d.question='project' "
            "WHERE e.status='closed' AND e.judged_hash = e.summary_hash AND e.end - e.start >= ? AND e.start > ? "
            "AND (d.confidence < ? OR d.answer = 'other') "
            "AND NOT EXISTS (SELECT 1 FROM labels l WHERE l.episode_id=e.id AND l.question='project') "
            "ORDER BY e.start DESC",
            (QSET, self.cfg["ask_min_s"], now - 3 * 86400, self.cfg["guess"])).fetchall()
        choices = [{"id": k, "label": v.split(":")[0].strip()} for k, v in sorted(self.projects.items())]
        choices += [{"id": "none", "label": "개인 용무·휴식"}, {"id": "other", "label": "목록에 없는 새 작업"}]
        for eid, st, en, app, title, summary in rows:
            if open_asks >= self.cfg["ask_open_max"]:
                break
            name = f"brain-ep-{eid}.json"
            if (INBOX / name).exists() or (done / name).exists():
                continue
            summ = json.loads(summary or "{}")
            hint = (summ.get("AI에게 한 질문") or summ.get("검색어") or summ.get("입력한 글", {}).get("예시") or [None])[-1]
            detail = " · ".join(x for x in [clip(title, 60) if title and title != app else None, clip(hint, 120) if hint else None] if x)
            t0 = datetime.fromtimestamp(st)
            item = {
                "id": name[:-5], "kind": "ask", "level": "yellow", "source": "brain", "episode_id": eid,
                "text": f"{t0.month}/{t0.day} {t0.strftime('%H:%M')}부터 {fmt_dur(en - st)} {app}에서 한 일은 어느 프로젝트?",
                "detail": detail or None, "choices": choices, "created": now, "expires": now + 7 * 86400,
            }
            write_atomic(INBOX / name, json.dumps(item, ensure_ascii=False, indent=2))
            os.chmod(INBOX / name, 0o600)
            open_asks += 1
            log(f"질문 남김: 구간 {eid} ({app} {fmt_dur(en - st)})")

    # 출력
    def label(self, q, ans_conf):
        if not ans_conf:
            return "판단 전"
        a, c = ans_conf
        if c >= self.cfg["accept"]:
            return f"{a}"
        if c >= self.cfg["guess"]:
            return f"{a}?"
        return "미분류"

    def render(self):
        if not self.dirty:
            return
        self.dirty = False
        now = datetime.now()
        day0 = now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        eps = self.db.execute("SELECT id, start, end, status, app, title, summary FROM episodes WHERE end >= ? ORDER BY start", (day0,)).fetchall()
        rows = []
        for eid, st, en, status, app, title, summary in eps:
            rows.append((eid, st, en, status, app, title, json.loads(summary), self.decisions(eid)))

        # 프로젝트·활동별 오늘 누적 (추정 이상만)
        by_proj, by_act = Counter(), Counter()
        for _, st, en, _, _, _, _, d in rows:
            dur = en - st
            p = d.get("project")
            a = d.get("activity")
            if p and p[1] >= self.cfg["guess"]:
                by_proj[p[0]] += dur
            if a and a[1] >= self.cfg["guess"]:
                by_act[a[0]] += dur

        cur = next((r for r in reversed(rows) if r[3] == "open"), None)
        lines = [f"# 지금 (갱신 {now.strftime('%H:%M:%S')})", ""]
        if cur and not self.seg.afk:
            eid, st, en, _, app, title, summ, d = cur
            lines += [
                f"- **활동**: {self.label('activity', d.get('activity'))} · **프로젝트**: {self.label('project', d.get('project'))} · **집중**: {focus_word(d.get('focus'))}",
                f"- **앱/창**: {app} — {clip(title, 90)}",
                f"- **시작**: {datetime.fromtimestamp(st).strftime('%H:%M')} ({fmt_dur(en - st)}째)",
            ]
            if d.get("project") and d["project"][1] >= self.cfg["guess"]:
                lines.append(f"- **오늘 이 프로젝트 누적**: {fmt_dur(by_proj.get(d['project'][0], 0))}")
            if summ.get("AI에게 한 질문"):
                lines.append(f"- **최근 AI 질문**: {clip(summ['AI에게 한 질문'][-1], 120)}")
            elif summ.get("입력한 글"):
                lines.append(f"- **최근 입력**: {clip(summ['입력한 글']['예시'][-1], 120)}")
            if summ.get("검색어"):
                lines.append(f"- **검색**: {', '.join(clip(s, 40) for s in summ['검색어'][-3:])}")
            stuck = d.get("stuck")
            if stuck and stuck[0] == "yes" and stuck[1] >= 0.4:
                lines.append("- ⚠︎ **막힘 신호**: 같은 문제를 반복 시도 중인 것 같음")
        else:
            lines.append("- 자리 비움 또는 기록 없음")
        lines += ["", "## 직전 흐름"]
        for eid, st, en, status, app, title, summ, d in [r for r in rows if r[3] == "closed"][-6:][::-1]:
            lines.append(f"- {datetime.fromtimestamp(st).strftime('%H:%M')}–{datetime.fromtimestamp(en).strftime('%H:%M')} "
                         f"{self.label('activity', d.get('activity'))} · {self.label('project', d.get('project'))} — {app}: {clip(title, 50)}")
        if by_proj:
            lines += ["", "## 오늘 프로젝트별 시간"]
            lines += [f"- {k}: {fmt_dur(v)}" for k, v in by_proj.most_common()]
        lines += ["", "<!-- ActLog brain이 자동으로 다시 씀. 표시: 확정 / 추정? / 미분류 -->"]
        write_atomic(self.wiki / "now.md", "\n".join(lines) + "\n")

        # 오늘 타임라인
        tl = [f"# {now.strftime('%Y-%m-%d')} 타임라인", "",
              "| 시간 | 길이 | 활동 | 프로젝트 | 집중 | 앱 · 내용 |", "|---|---|---|---|---|---|"]
        for eid, st, en, status, app, title, summ, d in rows:
            what = summ.get("AI에게 한 질문", [None])[-1] or (summ.get("검색어") or [None])[-1] or title or ""
            mark = " (진행 중)" if status == "open" else ""
            notable = " ★" if d.get("notable", ("no", 0))[0] == "yes" and d["notable"][1] >= 0.4 else ""
            tl.append(f"| {datetime.fromtimestamp(st).strftime('%H:%M')}{mark} | {fmt_dur(en - st)} | "
                      f"{self.label('activity', d.get('activity'))} | {self.label('project', d.get('project'))} | "
                      f"{focus_word(d.get('focus'))} | {app}: {clip(what, 60).replace('|', '/')}{notable} |")
        tl += ["", "## 합계", "", "**프로젝트**", ""] + [f"- {k}: {fmt_dur(v)}" for k, v in by_proj.most_common()]
        tl += ["", "**활동**", ""] + [f"- {k}: {fmt_dur(v)}" for k, v in by_act.most_common()]
        write_atomic(self.wiki / "timeline" / f"{now.strftime('%Y-%m-%d')}.md", "\n".join(tl) + "\n")


def focus_word(fc):
    if not fc:
        return "-"
    v = float(fc[0])
    return "깊음" if v >= 1.4 else ("보통" if v >= 0.6 else "산만")


# ───────────────────────── 실행 ─────────────────────────

def run(loop=True):
    b = Brain()
    log(f"brain 시작 (Clef {b.cfg['clef_url']}, 위키 {b.wiki})")
    # 밀린 기록은 조금씩 읽고 그때그때 시간순으로 판단한다
    # (뒤 구간 요약에 "이 앱에서 직전에 하던 프로젝트"가 들어가려면 앞 구간 판단이 먼저 있어야 함)
    while b.ingest(limit=300) == 300:
        while b.judge_pending(budget=20, oldest_first=True):
            pass
    while b.judge_pending(budget=20, oldest_first=True):
        pass
    b.render()
    if not loop:
        return b
    while True:
        b.ingest()
        b.judge_pending(budget=3)
        b.ask_unclear()
        b.render()
        time.sleep(3)


def status():
    db = sqlite3.connect(f"file:{BRAIN_DB}?mode=ro", uri=True)
    day0 = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    n, judged = db.execute("SELECT count(*), sum(judged_hash = summary_hash) FROM episodes WHERE start >= ?", (day0,)).fetchone()
    ms = db.execute("SELECT avg(ms) FROM (SELECT DISTINCT episode_id, ms FROM decisions WHERE ts >= ?)", (day0,)).fetchone()[0]
    print(f"오늘 구간 {n}개, 판단 완료 {judged or 0}개, Clef 평균 {int(ms or 0)}ms")
    for q in ("activity", "project"):
        rows = db.execute(f"SELECT answer, count(*), round(avg(confidence),2) FROM decisions d JOIN episodes e ON e.id=d.episode_id WHERE question=? AND e.start>=? GROUP BY answer ORDER BY 2 DESC", (q, day0)).fetchall()
        print(f"  {q}: " + ", ".join(f"{a} {c}개(신뢰 {conf})" for a, c, conf in rows))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        run(loop=True)
    elif cmd == "once":
        run(loop=False)
        status()
    elif cmd == "status":
        status()
    else:
        print(__doc__)
