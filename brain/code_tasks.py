"""고양이가 맡기는 코딩 작업: 허락받은 저장소의 git worktree 에서 Claude Code · Codex · Cursor · Grok CLI 를 무인으로 돌린다.

흐름 (docs/CAT_MIND.md "시키면 하기"):
  1. 대화 답의 actions 에 {tool: "code", arg: 저장소 이름, detail: 할 일} 이 오면 cat_mind 가 늘 먼저 묻는다 (어느 도구로 · 안 돼).
  2. 고르면 start(): 저장소에 브랜치 meowgent/<id> 로 worktree 를 만들고, 그 안에서 CLI 를 백그라운드로 띄운다.
     실행은 sh 로 감싸 끝나면 exit 파일을 남긴다 (cat_mind 가 다시 켜져도 이어서 본다).
  3. poll(): 끝난 작업은 worktree 에서 커밋하고(에이전트는 커밋하지 않게 시킨다) 바뀐 파일 수·요약을 돌려준다.
  4. 사용자가 고르면 merge() (기본 브랜치에 --no-ff 합치기, 푸시는 안 함) 또는 discard() (worktree·브랜치 지우기).

에이전트 실행 방식은 Agent Hub 의 src/dispatch/agent-job.sh 와 같다. Codex 는 고양이 계정이 아니라 사용자 평소 계정(~/.codex)을 쓴다.
mind/tasks/<id>/task.json 이 상태 하나 (대시보드 "작업" 탭이 읽는다), 파일 0600.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

AGENTS = {
    "claude": "Claude Code",
    "codex": "Codex",
    "cursor": "Cursor",
    "grok": "Grok",
}
BINS = {"claude": "claude", "codex": "codex", "cursor": "cursor-agent", "grok": "grok"}
EXTRA_PATH = [str(Path.home() / ".local/bin"), str(Path.home() / ".grok/bin"), "/opt/homebrew/bin", "/usr/local/bin"]
# Claude Code 는 acceptEdits(파일 고치기만 자동). 확인용 명령만 더 연다 (빌드·테스트는 아래 샌드박스 안에서만 돈다)
CLAUDE_TOOLS = ["Bash(git diff:*)", "Bash(git status:*)", "Bash(git log:*)", "Bash(swift build:*)", "Bash(python3 -I:*)", "Bash(ls:*)"]
# Codex 는 자체 샌드박스(workspace-write)가 있다. 나머지 셋은 자동 승인으로 돌므로 macOS 샌드박스(sandbox-exec)로 감싸
# 쓰기를 worktree · 그 git 폴더 · 도구 자기 설정 · 임시 폴더로 막는다. 읽기와 네트워크(모델 API)는 막지 않는다
SANDBOXED = {"claude", "cursor", "grok"}
TOOL_HOMES = {"claude": [".claude", ".claude.json", ".config/claude"], "cursor": [".cursor", ".config/cursor"],
              "grok": [".grok", ".config/grok"]}


def sandbox_profile(agent, writable):
    home = Path.home()
    allow = [*map(str, writable), "/private/tmp", "/private/var/folders", str(home / "Library/Caches"),
             *(str(home / h) for h in TOOL_HOMES.get(agent, []))]
    rules = " ".join(f'(subpath "{a}")' for a in allow if '"' not in a and "\\" not in a)
    # ~/.claude.json 은 바꿔 쓸 때 옆에 임시·백업 파일을 만든다
    extra = f' (regex #"^{re.escape(str(home))}/\\.claude\\.json")' if agent == "claude" else ""
    return f'(version 1)(allow default)(deny file-write*)(allow file-write* {rules}{extra} (regex #"^/dev/"))'


def write_private(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(text)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def find_bin(agent, path_env=None):
    path = os.pathsep.join([*(path_env or os.environ.get("PATH", "")).split(os.pathsep), *EXTRA_PATH])
    return shutil.which(BINS[agent], path=path)


def git(repo, *args, timeout=60):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def brief(task, request, repo_name, branch):
    return "\n".join([
        f"너는 `{repo_name}` 저장소의 git worktree(브랜치 `{branch}`) 안에서 일한다. 지금 폴더가 그 worktree 다.",
        "", "# 할 일", task.strip(), "",
        "# 사용자가 고양이(Meowgent)에게 한 원래 말 (참고용 데이터)", f"\"{request.strip()}\"", "",
        "# 규칙",
        "- 이 폴더 안의 파일만 고친다. 저장소의 AGENTS.md · CLAUDE.md 규칙이 있으면 따른다.",
        "- git commit · push · 브랜치 바꾸기 · worktree 지우기를 하지 않는다. 끝나면 Meowgent 가 커밋한다.",
        "- 배포, 외부로 보내기, 저장소 밖 파일 지우기처럼 되돌리기 어려운 일은 하지 않는다.",
        "- 할 일이 애매하면 가장 작고 안전한 해석으로 하고, 무엇을 가정했는지 마지막 답에 적는다.",
        "- 끝나면 마지막 답에 한국어로 3줄 이내로 쓴다: 바꾼 것 / 확인한 것 / 확인 못 한 것.",
    ])


def command(agent, bin_path, prompt, wt, last):
    if agent == "claude":
        cmd = [bin_path, "-p", prompt, "--output-format", "json", "--permission-mode", "acceptEdits"]
        for t in CLAUDE_TOOLS:
            cmd += ["--allowedTools", t]
        return cmd
    if agent == "codex":
        return [bin_path, "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--color", "never",
                "-C", str(wt), "-o", str(last), prompt]
    if agent == "cursor":
        return [bin_path, "-p", "--trust", "--force", "--output-format", "json", "--workspace", str(wt), prompt]
    if agent == "grok":
        return [bin_path, "-p", prompt, "--output-format", "json", "--always-approve", "--cwd", str(wt)]
    raise ValueError(agent)


def final_message(d: Path):
    """에이전트 마지막 답: codex 는 -o 파일, 나머지는 stdout JSON 의 result/text, 아니면 stdout 끝부분"""
    last = d / "last.txt"
    if last.exists() and last.read_text(errors="replace").strip():
        return last.read_text(errors="replace").strip()
    out = (d / "stdout.txt").read_text(errors="replace") if (d / "stdout.txt").exists() else ""
    for chunk in [out.strip(), *reversed(out.strip().splitlines())]:
        try:
            o = json.loads(chunk)
        except ValueError:
            continue
        if isinstance(o, dict):
            for k in ("result", "text", "message", "content"):
                if isinstance(o.get(k), str) and o[k].strip():
                    return o[k].strip()
    return out.strip()[-600:]


class Tasks:
    def __init__(self, mind_dir: Path, cfg, now=time.time, log=print):
        self.dir = mind_dir / "tasks"
        self.cfg = cfg
        self.now = now
        self.log = log

    # 저장소·도구
    def repos(self):
        """허락한 저장소 {이름: 경로}. 실제 git 저장소만"""
        out = {}
        for name, p in (self.cfg.get("code_repos") or {}).items():
            path = Path(os.path.expanduser(str(p)))
            if (path / ".git").exists():
                out[str(name)] = path
        return out

    def agents(self):
        """설치된 도구, 설정 순서대로"""
        order = [a for a in self.cfg.get("code_agents") or list(AGENTS) if a in AGENTS]
        return [a for a in order if find_bin(a)]

    # 상태
    def all(self):
        if not self.dir.exists():
            return []
        items = [read_json(f, None) for f in self.dir.glob("*/task.json")]
        return sorted((t for t in items if t), key=lambda t: t["created"])

    def get(self, tid):
        return read_json(self.dir / tid / "task.json", None)

    def save(self, t):
        write_private(self.dir / t["id"] / "task.json", json.dumps(t, ensure_ascii=False, indent=2))

    def running(self):
        return [t for t in self.all() if t["state"] == "running"]

    # 시작
    def start(self, agent, repo_name, task, request):
        """작업 하나를 띄운다. (task dict, 오류 글) 중 하나"""
        repos = self.repos()
        if repo_name not in repos:
            return None, f"{repo_name}은(는) 허락한 저장소가 아니다"
        if agent not in AGENTS or not find_bin(agent):
            return None, f"{AGENTS.get(agent, agent)}이(가) 이 맥에 없다"
        if len(self.running()) >= int(self.cfg.get("code_max_running", 2)):
            return None, "이미 작업이 여러 개 돌고 있다"
        repo = repos[repo_name]
        tid = time.strftime("%Y%m%d-%H%M%S", time.localtime(self.now())) + f"-{agent}"
        branch = f"meowgent/{tid}"
        d = self.dir / tid
        wt = d / "wt"
        d.mkdir(parents=True, exist_ok=True)
        os.chmod(d, 0o700)
        code, base = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
        if code != 0:
            return None, "저장소 상태를 못 읽었다"
        code, out = git(repo, "worktree", "add", "-b", branch, str(wt), "HEAD")
        if code != 0:
            self.log(f"worktree 실패: {clip(out, 300)}")
            return None, "worktree를 못 만들었다"
        prompt = brief(task, request, repo_name, branch)
        cmd = command(agent, find_bin(agent), prompt, wt, d / "last.txt")
        if agent in SANDBOXED:
            _, gitdir = git(wt, "rev-parse", "--absolute-git-dir")   # repo/.git/worktrees/<이름>: 인덱스만 여기에 쓴다
            cmd = ["/usr/bin/sandbox-exec", "-p", sandbox_profile(agent, [wt, gitdir]), *cmd]
        env = {k: v for k, v in os.environ.items() if k != "CODEX_HOME"}   # 고양이 전용 Codex 계정이 아니라 평소 계정
        env["PATH"] = os.pathsep.join([env.get("PATH", "/usr/bin:/bin"), *EXTRA_PATH])
        # sh 로 감싸 끝나면 exit 파일을 남긴다: cat_mind 가 다시 켜져도 끝난 걸 안다
        wrapper = ['sh', '-c', '"$@" </dev/null >"$D/stdout.txt" 2>"$D/stderr.log"; echo $? >"$D/exit"', "task"] + cmd
        proc = subprocess.Popen(wrapper, cwd=wt, env={**env, "D": str(d)}, start_new_session=True,
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t = {"id": tid, "agent": agent, "agent_name": AGENTS[agent], "repo": repo_name, "repo_path": str(repo),
             "base": base, "branch": branch, "worktree": str(wt), "task": task, "request": request,
             "state": "running", "pid": proc.pid, "created": self.now(), "started": self.now()}
        self.save(t)
        self.log(f"코딩 작업 시작: {tid} {repo_name} ({AGENTS[agent]})")
        return t, None

    # 지켜보기
    def poll(self):
        """끝난 작업들 (state 가 done·failed·timeout·cancelled 로 막 바뀐 것)"""
        finished = []
        for t in self.running():
            d = self.dir / t["id"]
            cancel = (d / "cancel").exists()
            over = self.now() - t["started"] > float(self.cfg.get("code_timeout_s", 3600))
            if not (d / "exit").exists() and (cancel or over):
                self.kill(t)
                t["state"] = "cancelled" if cancel else "timeout"
            elif (d / "exit").exists():
                code = (d / "exit").read_text().strip()
                t["exit"] = int(code) if code.lstrip("-").isdigit() else None
                t["state"] = "done" if t["exit"] == 0 else "failed"
            elif not alive(t.get("pid")):
                t["state"] = "failed"
                t["exit"] = None
            else:
                continue
            t["ended"] = self.now()
            t["summary"] = clip(final_message(d), 800)
            if t["state"] != "done":
                err = (d / "stderr.log").read_text(errors="replace")[-300:] if (d / "stderr.log").exists() else ""
                t["error"] = clip(err, 300)
            t["files"], t["stat"] = self.commit(t)
            self.save(t)
            self.log(f"코딩 작업 끝: {t['id']} {t['state']} 파일 {t['files']}개")
            finished.append(t)
        return finished

    def kill(self, t):
        try:
            os.killpg(int(t["pid"]), signal.SIGTERM)
        except (OSError, TypeError, ValueError):
            pass

    def commit(self, t):
        """worktree 의 바뀐 것을 커밋. (바뀐 파일 수, diff --stat 끝 줄)"""
        wt = t["worktree"]
        git(wt, "add", "-A")
        code, names = git(wt, "diff", "--cached", "--name-only")
        files = [n for n in names.splitlines() if n.strip()] if code == 0 else []
        if not files:
            return 0, ""
        msg = f"묘전트 작업 ({t['agent_name']}): {clip(t['task'], 60)}\n\n사용자 요청: {clip(t['request'], 200)}"
        git(wt, "-c", "user.name=Meowgent", "-c", "user.email=meowgent@localhost", "commit", "-q", "-m", msg)
        _, stat = git(wt, "diff", "--stat", f"{t['base']}...HEAD")
        return len(files), (stat.splitlines() or [""])[-1].strip()

    # 끝난 뒤
    def merge(self, tid):
        """기본 브랜치(작업 시작 때 HEAD)에 합친다. 저장소가 그 브랜치에 있고 깨끗할 때만. 푸시는 하지 않는다"""
        t = self.get(tid)
        if not t:
            return False, "작업을 못 찾았다"
        repo = t["repo_path"]
        _, head = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
        if head != t["base"]:
            return False, f"{t['base']}에서 시작한 작업인데 저장소가 지금 {head} 브랜치라 안 합쳤다"
        _, dirty = git(repo, "status", "--porcelain", "--untracked-files=no")
        if dirty:
            return False, "저장소에 커밋 안 한 변경이 있어서 안 합쳤다"
        code, out = git(repo, "merge", "--no-ff", "--no-edit", t["branch"])
        if code != 0:
            git(repo, "merge", "--abort")
            return False, "충돌이 나서 합치기를 되돌렸다. 브랜치는 그대로 있다"
        self.cleanup(t, delete_branch=True)
        t["state"] = "merged"
        self.save(t)
        return True, f"{t['base']}에 합쳤다. 푸시는 안 했다"

    def discard(self, tid):
        t = self.get(tid)
        if not t:
            return False, "작업을 못 찾았다"
        self.cleanup(t, delete_branch=True, force=True)
        t["state"] = "discarded"
        self.save(t)
        return True, "버렸다"

    def cleanup(self, t, delete_branch=False, force=False):
        git(t["repo_path"], "worktree", "remove", *(["--force"] if force else []), t["worktree"])
        if delete_branch:
            git(t["repo_path"], "branch", "-D" if force else "-d", t["branch"])

    def write_summary(self, mind_dir: Path):
        """mind/tasks.json: 앱 대화창 상태 줄용 짧은 요약"""
        ts = self.all()
        write_private(mind_dir / "tasks.json", json.dumps({
            "running": [{"id": t["id"], "agent": t["agent_name"], "repo": t["repo"], "task": clip(t["task"], 60), "started": t["started"]}
                        for t in ts if t["state"] == "running"],
            "ts": self.now()}, ensure_ascii=False))


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def clip(s, n):
    s = re.sub(r"\s+\n", "\n", str(s or "")).strip()
    return s if len(s) <= n else s[: n - 1] + "…"
