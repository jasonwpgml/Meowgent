#!/usr/bin/env bash
# Meowgent 개발 빌드 → ~/Applications/Meowgent.app 설치 → 실행
# 서명: 키체인의 "ActLog Local Signing" 인증서(이 맥 전용, 자체 서명)로 서명한다.
#       인증서가 같으면 다시 빌드해도 macOS 권한(손쉬운 사용·입력 모니터링)이 유지된다.
#       인증서가 없으면 임시 서명(ad-hoc)으로 떨어지고, 그때는 빌드마다 권한을 다시 켜야 한다.
# 배포본은 release.sh 로 만든다.
set -euo pipefail
cd "$(dirname "$0")"
APP_ID=io.github.jasonwpgml.meowgent

./setup-pet.sh
swift build -c release
BUNDLE=.build/Meowgent.app
INCLUDE_VENDOR="${INCLUDE_VENDOR:-1}" ./bundle.sh "$BUNDLE"
SIGN_ID="${SIGN_ID:-$(security find-identity -p codesigning | awk '/"ActLog Local Signing"/ {print $2; exit}')}"
[[ -n "$SIGN_ID" ]] || echo "경고: ActLog Local Signing 인증서 없음 → 임시 서명 (빌드마다 권한 재설정 필요)"
codesign --force --sign "${SIGN_ID:--}" --identifier "$APP_ID" "$BUNDLE"

DEST="$HOME/Applications/Meowgent.app"
# 이름 바꾸기 전 설치(ActLog.app)가 돌고 있으면 끄고, 옛 LaunchAgent도 내린다
if pgrep -x ActLog >/dev/null; then
  launchctl bootout "gui/$(id -u)/com.jason.actlog" 2>/dev/null || true
  osascript -e 'tell application id "com.jason.actlog" to quit' 2>/dev/null || pkill -x ActLog || true
  sleep 1
fi
if pgrep -x Meowgent >/dev/null; then
  osascript -e "tell application id \"$APP_ID\" to quit" 2>/dev/null || pkill -x Meowgent || true
  sleep 1
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUNDLE" "$DEST"
echo "설치됨: $DEST"
[[ "${NO_OPEN:-}" == 1 ]] && exit 0
# 자동 재시작(launchd)에 등록돼 있으면 launchd로 다시 띄우고, 아니면 그냥 연다
if launchctl print "gui/$(id -u)/$APP_ID" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$APP_ID"
else
  open "$DEST"
fi
