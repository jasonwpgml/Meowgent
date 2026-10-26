"""Clef-flash 활동 분류 프로브: 지연, 접두 캐시 효과, 이미지 입력 형식 확인."""
import base64, io, json, sys, time, urllib.request, urllib.error
from PIL import Image, ImageDraw, ImageFont

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8010"

def post(body, path="/v1/systemone"):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    t = time.time()
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())
    except urllib.error.HTTPError as e:
        return None, (time.time() - t) * 1000, e.read().decode()[:400]
    return r, (time.time() - t) * 1000, None

PROJECTS = {
    "infohub": "sample-app: 개인 사이드 프로젝트 (~/dev/projects/sample-app) (예시)",
    "theailab": "theailab: 회사 AI 랩 업무 (~/dev/work/theailab, Bearable 수강신청 도우미 등)",
    "llm_wiki": "LLM wiki / 활동 수집기 만들기",
    "job": "취업 서류: 이력서, 포트폴리오, 자기소개서",
    "personal": "개인 용무: 쇼핑, 금융, 연락, 엔터테인먼트",
}
ACTIVITY = {
    "coding": "코드 작성/수정/디버깅",
    "agent_chat": "AI 에이전트(Claude/Codex)와 대화하며 작업",
    "reading": "문서/웹페이지/논문 읽기, 리서치",
    "writing": "문서·글 작성",
    "communication": "메신저/메일/회의",
    "design": "Figma 등 디자인",
    "admin": "설정, 파일 정리, 잡무",
    "leisure": "휴식/엔터테인먼트",
}

def questions():
    return {
        "activity": {"type": "choice", "instructions": "이 구간에서 사용자가 주로 하는 활동은?", "criteria": ACTIVITY},
        "project": {"type": "choice", "instructions": "이 구간의 작업은 어느 프로젝트에 속하는가?", "criteria": PROJECTS},
        "focus": {"type": "score", "instructions": "이 구간에서 사용자의 집중도는?", "criteria": ["산만함(잦은 전환)", "보통", "깊은 집중"]},
        "switched": {"type": "noul", "instructions": "직전 구간과 비교해 작업 맥락(프로젝트나 목표)이 바뀌었는가?"},
    }

SEGMENTS = [
    {"prev": "14:02-14:09 VS Code / sample-app / src/sync/feed.ts 편집",
     "now": {"t": "14:09-14:16", "app": "Google Chrome", "title": "Pull requests · me/sample-app",
             "url": "https://github.com/me/sample-app/pulls", "clicks": ["link 'feat: feed sync'", "tab 'Files changed'", "button 'Approve'"],
             "typed_chars": 42, "typed_sample": "LGTM, 캐시 무효화만 확인", "idle_s": 20, "switches": 2}},
    {"prev": "14:09-14:16 Chrome / GitHub sample-app PR 리뷰",
     "now": {"t": "14:16-14:21", "app": "KakaoTalk", "title": "엄마", "clicks": ["textarea"],
             "typed_chars": 30, "typed_sample": "응 저녁에 갈게", "idle_s": 5, "switches": 1}},
    {"prev": "14:21-14:30 Claude / 활동 수집기 설계 대화",
     "now": {"t": "14:30-14:52", "app": "Code", "title": "collector/main.swift — awlog",
             "clicks": ["menu 'Run'", "button 'Build'"], "typed_chars": 1830,
             "typed_sample": "CGEvent.tapCreate(tap: .cgSessionEventTap", "idle_s": 40, "switches": 0}},
    {"prev": "14:52-15:01 Code / collector/main.swift",
     "now": {"t": "15:01-15:09", "app": "Google Chrome", "title": "YouTube",
             "url": "https://www.youtube.com/watch?v=xxxx", "clicks": ["button 'Skip ad'", "link '다음 영상'"],
             "typed_chars": 0, "idle_s": 200, "switches": 6}},
]

print("== 텍스트 분류 (구간 4개, 각 3회 반복해 캐시 효과 측정) ==")
for seg in SEGMENTS:
    state = json.dumps(seg, ensure_ascii=False)
    times = []
    for _ in range(3):
        r, ms, err = post({"model": "default", "state": state, "questions": questions()})
        times.append(ms)
    if err:
        print("ERR", err); continue
    ans = r.get("answers", {})
    short = {k: (v.get("choice") or v.get("score") or v.get("noul"), round(v.get("confidence") or 0, 2)) if isinstance(v, dict) else v for k, v in ans.items()}
    print(f"{seg['now']['app']:14s} {seg['now'].get('title','')[:28]:28s} ms={[round(x) for x in times]} {short}")

print("\n== 응답 원문 1개 ==")
r, ms, err = post({"model": "default", "state": json.dumps(SEGMENTS[0], ensure_ascii=False), "questions": questions()})
print(json.dumps(r, ensure_ascii=False)[:1200])

# 가짜 UI 스크린샷 생성
img = Image.new("RGB", (1280, 800), "white")
d = ImageDraw.Draw(img)
try:
    font = ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", 28)
except Exception:
    font = ImageFont.load_default()
d.rectangle([0, 0, 1280, 60], fill=(36, 41, 47))
d.text((20, 15), "GitHub  me/sample-app  Pull requests", fill="white", font=font)
d.text((40, 120), "feat: feed sync with cache invalidation  #42", fill="black", font=font)
d.rectangle([1000, 700, 1220, 760], fill=(31, 136, 61))
d.text((1040, 712), "Approve", fill="white", font=font)
buf = io.BytesIO(); img.save(buf, "PNG")
b64 = base64.b64encode(buf.getvalue()).decode()
uri = "data:image/png;base64," + b64

q_img = {"site": {"type": "choice", "instructions": "화면에 보이는 것은?",
                  "criteria": {"github_pr": "GitHub 풀 리퀘스트 페이지", "youtube": "YouTube 영상", "editor": "코드 에디터", "chat": "메신저"}}}
variants = {
    "state=content parts (openai style)": {"state": [{"type": "text", "text": "현재 화면"}, {"type": "image_url", "image_url": {"url": uri}}]},
    "images field": {"state": "현재 화면", "images": [uri]},
    "image field": {"state": "현재 화면", "image": uri},
    "state=[image_url only]": {"state": [{"type": "image_url", "image_url": {"url": uri}}]},
    "media field": {"state": "현재 화면", "media": [{"type": "image", "data": b64}]},
}
print("\n== 이미지 입력 형식 프로브 ==")
for name, extra in variants.items():
    body = {"model": "default", "questions": q_img, **extra}
    r, ms, err = post(body)
    if err:
        print(f"{name:38s} HTTP ERR {err[:200]}")
    else:
        a = r.get("answers", {}).get("site", {})
        print(f"{name:38s} {round(ms)}ms -> {a.get('choice')} conf={a.get('confidence')} usage={r.get('usage')}")
