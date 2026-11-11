#!/usr/bin/env bash
# post-commit 훅이 백그라운드로 띄우는 일꾼: .build/autodeploy/pending-<대상> 이 있는 것만 다시 깐다.
#   한 번에 하나만 돈다. 도는 중에 새 커밋이 오면 pending 만 남기고, 이쪽이 끝난 뒤 한 번 더 돈다.
#   기록: .build/autodeploy/last.log (마지막 실행 전체) · history.log (한 줄 요약)
#   실패하면 고양이 inbox 에 빨강 ! 를 넣고, 다음에 성공하면 지운다 (docs/INBOX.md).
# 커밋한 내용이 아니라 지금 작업 폴더를 빌드한다 (손으로 build.sh 를 돌릴 때와 같다).
set -u
root=${1:?저장소 경로}
state="$root/.build/autodeploy"
inbox="$HOME/Library/Application Support/Meowgent/inbox"
export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
mkdir -p "$state"

run_target() {
  case "$1" in
    app) ${MEOWGENT_APP_CMD:-"$root/collector/build.sh"} ;;
    brain) ${MEOWGENT_BRAIN_CMD:-"$root/brain/install.sh"} ;;
  esac
}
label() { [[ "$1" == app ]] && echo "앱 빌드" || echo "brain 설치"; }

notify_fail() {  # $1 대상
  [[ -d "$inbox" ]] || return 0
  LABEL=$(label "$1") LOG="$state/last.log" OUT="$inbox/autodeploy-$1.json" python3 -I - <<'PY'
import json, os, time
log = os.environ["LOG"]
tail = open(log, errors="replace").read().strip().splitlines()[-6:]
item = {"id": os.path.basename(os.environ["OUT"])[:-5], "kind": "todo", "level": "red",
        "text": f"커밋 뒤 자동 적용 실패 ({os.environ['LABEL']})",
        "detail": "\n".join(tail)[-600:] + f"\n전체 기록: {log}",
        "source": "autodeploy", "created": int(time.time()), "expires": int(time.time()) + 86400}
tmp = os.environ["OUT"] + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f: json.dump(item, f, ensure_ascii=False)
os.replace(tmp, os.environ["OUT"])
PY
}

while :; do
  if ! mkdir "$state/lock" 2>/dev/null; then
    # 일꾼이 죽어 남은 잠금이면 치우고 다시 잡는다
    kill -0 "$(cat "$state/lock/pid" 2>/dev/null)" 2>/dev/null && exit 0
    rm -rf "$state/lock"; continue
  fi
  echo $$ > "$state/lock/pid"
  : > "$state/last.log"
  for t in app brain; do
    [[ -e "$state/pending-$t" ]] || continue
    rm -f "$state/pending-$t"
    head=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)
    start=$(date +%s)
    echo "== $(date '+%F %T') $head $(label "$t")" >> "$state/last.log"
    if run_target "$t" >> "$state/last.log" 2>&1; then
      rm -f "$inbox/autodeploy-$t.json"
      echo "$(date '+%F %T') $head $(label "$t") 성공 ($(( $(date +%s) - start ))초)" >> "$state/history.log"
    else
      echo "$(date '+%F %T') $head $(label "$t") 실패 ($(( $(date +%s) - start ))초)" >> "$state/history.log"
      notify_fail "$t"
    fi
  done
  rm -rf "$state/lock"
  # 잠금을 푸는 사이에 들어온 커밋이 있으면 한 번 더
  [[ -e "$state/pending-app" || -e "$state/pending-brain" ]] || break
done
