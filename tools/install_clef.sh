#!/usr/bin/env bash
# Clef-flash 판단 서버를 로그인 시 자동 실행 (launchd). 꺼지면 다시 켠다. 메모리 약 10GB 상주.
#   ./tools/install_clef.sh          설치·재시작
#   ./tools/install_clef.sh remove   해제
set -euo pipefail
LABEL="com.jason.meowgent.clef"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
if [[ "${1:-}" == "remove" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; echo "해제됨"; exit 0
fi
SNAP=$(ls -d "$HOME"/.cache/huggingface/hub/models--ggml-org--Clef-Flash-GGUF/snapshots/*/ | head -1)
MODEL="$SNAP/Clef-Flash-Q8_0.gguf"; MMPROJ="$SNAP/mmproj-Clef-Flash-Q8_0.gguf"
[[ -f "$MODEL" ]] || { echo "모델 파일 없음: $MODEL"; exit 1; }
BIN="$(command -v llama-server)"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array>
        <string>$BIN</string>
        <string>-m</string><string>$MODEL</string>
        <string>--mmproj</string><string>$MMPROJ</string>
        <string>--host</string><string>127.0.0.1</string>
        <string>--port</string><string>8010</string>
        <string>-c</string><string>8192</string>
        <string>-b</string><string>8192</string>
        <string>-ub</string><string>8192</string>
    </array>
    <!-- Homebrew llama.cpp 0.6.0 Metal 퓨전 버그 회피 (PR #30100 들어간 버전이면 지워도 됨) -->
    <key>EnvironmentVariables</key><dict><key>GGML_METAL_FUSION_DISABLE</key><string>1</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/meowgent-clef.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/meowgent-clef.log</string>
</dict>
</plist>
PL
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# 손으로 띄운 서버가 8010을 쓰고 있으면 넘겨받는다
OLD=$(lsof -tiTCP:8010 -sTCP:LISTEN 2>/dev/null || true)
[[ -n "$OLD" ]] && { echo "기존 서버(pid $OLD) 종료 후 넘겨받음"; kill $OLD; sleep 2; }
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "설치됨: $PLIST"
