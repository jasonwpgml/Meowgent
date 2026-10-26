#!/usr/bin/env bash
# Meowgent 배포본 만들기 → dist/
#
#   Developer ID가 있을 때 (공증까지):
#     SIGN_ID="Developer ID Application: 이름 (TEAMID)" NOTARY_PROFILE=meowgent ./release.sh
#     (NOTARY_PROFILE 은 미리 한 번: xcrun notarytool store-credentials meowgent --apple-id <애플ID> --team-id <TEAMID> --password <앱 암호>)
#   없을 때 (임시 서명 zip — 받는 쪽에서 "그래도 열기"가 필요하다):
#     ./release.sh
#
# 팩 그림(재배포 금지)은 넣지 않는다. 심볼은 떼어 낸다.
set -euo pipefail
cd "$(dirname "$0")"
APP_ID=io.github.jasonwpgml.meowgent
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DIST=dist
APP="$DIST/Meowgent.app"

./setup-pet.sh
[[ -f ../pet/Sources/PetController.swift ]] || { echo "배포본에는 고양이가 필요하다 (pet/ 서브모듈: git submodule update --init)" >&2; exit 1; }
swift build -c release
mkdir -p "$DIST"
INCLUDE_VENDOR=0 ./bundle.sh "$APP"
strip -x "$APP/Contents/MacOS/Meowgent"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements Meowgent.entitlements \
    --identifier "$APP_ID" --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"

  # DMG: 앱 + Applications 바로가기
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="$DIST/Meowgent-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname "Meowgent" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG" || true
  else
    echo "NOTARY_PROFILE 이 없어 공증은 건너뜀. 받는 쪽에서 Gatekeeper 에 막힌다."
  fi
  echo "완료: $DMG"
else
  codesign --force --sign - --identifier "$APP_ID" "$APP"
  ZIP="$DIST/Meowgent-$VERSION-unsigned.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  cat <<MSG
완료: $ZIP  (임시 서명)
받는 쪽 안내:
  1. 압축을 풀고 Meowgent.app 을 응용 프로그램 폴더로 옮긴다.
  2. 처음 열면 "Apple이 확인할 수 없음"이 뜬다 → 시스템 설정 › 개인 정보 보호 및 보안 › 아래쪽 "그래도 열기".
     또는 터미널: xattr -cr /Applications/Meowgent.app
  3. 업데이트마다 손쉬운 사용·입력 모니터링 권한을 다시 켜야 한다 (임시 서명은 빌드마다 서명이 바뀜).
Developer ID 를 받으면 SIGN_ID 와 NOTARY_PROFILE 만 넣어 다시 실행하면 된다.
MSG
fi
