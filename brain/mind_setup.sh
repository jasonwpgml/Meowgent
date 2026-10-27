#!/usr/bin/env bash
# 말하는 고양이(cat_mind)가 쓸 Codex 전용 홈을 만들고 로그인한다.
# 평소 쓰는 ~/.codex 와 계정·설정·기록이 섞이지 않게 따로 둔다.
#   ./mind_setup.sh            설정 쓰기 + (안 돼 있으면) 브라우저 로그인
#   ./mind_setup.sh status     로그인한 계정 확인
set -euo pipefail
HOME_DIR="${MEOWGENT_CODEX_HOME:-$HOME/.codex-meowgent}"
mkdir -p "$HOME_DIR"
chmod 700 "$HOME_DIR"

# 고양이는 말만 한다: 셸·브라우저·플러그인·이미지·웹 검색 같은 도구를 모두 끈다
cat > "$HOME_DIR/config.toml" <<'TOML'
model = "gpt-6-luna"
model_reasoning_effort = "low"
web_search = "disabled"
check_for_update_on_startup = false

[features]
shell_tool = false
unified_exec = false
apps = false
plugins = false
remote_plugin = false
multi_agent = false
image_generation = false
browser_use = false
browser_use_external = false
in_app_browser = false
computer_use = false
hooks = false
memories = false
skill_search = false
tool_suggest = false
view_image = false
goals = false
TOML

whoami_codex() {
  python3 - "$HOME_DIR/auth.json" <<'PY'
import base64, json, sys
try:
    a = json.load(open(sys.argv[1]))
    t = a["tokens"]["id_token"].split(".")[1]
    d = json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4)))
    print(d.get("email", "?"), d.get("https://api.openai.com/auth", {}).get("chatgpt_plan_type", ""))
except Exception:
    print("로그인 안 됨")
PY
}

if [[ "${1:-}" == "status" ]]; then whoami_codex; exit 0; fi

if ! CODEX_HOME="$HOME_DIR" codex login status >/dev/null 2>&1; then
  echo "브라우저가 열리면 고양이에게 줄 계정으로 로그인하세요 (평소 쓰는 ~/.codex 는 그대로 둡니다)."
  CODEX_HOME="$HOME_DIR" codex login
fi
echo "고양이 Codex 계정: $(whoami_codex)  ($HOME_DIR)"
