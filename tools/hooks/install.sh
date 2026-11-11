#!/usr/bin/env bash
# 커밋 뒤 자동 적용 훅을 이 저장소에 건다 (.git/hooks 는 git 에 안 올라가서 받은 기기마다 한 번 실행).
#   ./tools/hooks/install.sh            걸기
#   ./tools/hooks/install.sh --remove   떼기
set -euo pipefail
cd "$(dirname "$0")/../.."
hook="$(git rev-parse --git-common-dir)/hooks/post-commit"
if [[ "${1:-}" == --remove ]]; then
  [[ -L "$hook" ]] && rm "$hook" && echo "뗌: $hook"
  exit 0
fi
if [[ -e "$hook" && ! -L "$hook" ]]; then
  echo "이미 다른 post-commit 훅이 있어 건드리지 않았다: $hook" >&2
  exit 1
fi
chmod +x tools/hooks/post-commit tools/hooks/autodeploy.sh
ln -sfn "$PWD/tools/hooks/post-commit" "$hook"
echo "걸림: $hook → tools/hooks/post-commit"
