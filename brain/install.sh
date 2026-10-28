#!/usr/bin/env bash
# ActLog brain(2단계 판단기) 설치: 스크립트를 데이터 폴더로 복사하고 launchd로 상시 실행
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/ActLog/brain"
PLIST="$HOME/Library/LaunchAgents/com.jason.actlog.brain.plist"
LABEL="com.jason.actlog.brain"
PY="$(command -v python3)"

mkdir -p "$DEST"
cp actlog_brain.py "$DEST/actlog_brain.py"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array>
        <string>$PY</string><string>-I</string><string>$DEST/actlog_brain.py</string><string>run</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Background</string>
    <key>Nice</key><integer>5</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "설치됨: $DEST/actlog_brain.py (launchd: $LABEL)"

# 말하는 고양이 (cat_mind). Codex 계정은 ./mind_setup.sh 로 따로 로그인한다
MIND_LABEL="com.jason.meowgent.mind"
MIND_PLIST="$HOME/Library/LaunchAgents/$MIND_LABEL.plist"
MIND_DIR="$HOME/Library/Application Support/Meowgent/mind"
cp cat_mind.py "$DEST/cat_mind.py"
mkdir -p "$MIND_DIR" && chmod 700 "$MIND_DIR"
# 말하는 고양이의 성격 (없으면 cat_mind 의 DEFAULT_PERSONA)
install -m 600 persona.md "$MIND_DIR/persona.md"
cat > "$MIND_PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$MIND_LABEL</string>
    <key>ProgramArguments</key><array>
        <string>$PY</string><string>-I</string><string>$DEST/cat_mind.py</string><string>run</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Background</string>
    <key>Nice</key><integer>5</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)/$MIND_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$MIND_PLIST"
echo "설치됨: $DEST/cat_mind.py (launchd: $MIND_LABEL) — 끄기: 고양이 메뉴 '🧠 말하는 고양이'"
