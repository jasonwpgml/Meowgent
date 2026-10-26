#!/usr/bin/env bash
# 빌드된 실행 파일을 Meowgent.app 번들로 묶는다 (서명은 하지 않음). build.sh·release.sh가 쓴다.
# 사용: ./bundle.sh <출력 .app 경로>   [INCLUDE_VENDOR=1 이면 재배포 금지 팩 그림도 넣는다 — 개발 빌드 전용]
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE="${1:?출력 .app 경로}"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/cats/original" "$BUNDLE/Contents/Resources/fonts"
cp .build/release/ActLog "$BUNDLE/Contents/MacOS/Meowgent"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp LICENSES.md "$BUNDLE/Contents/Resources/LICENSES.md"
cp ../assets/fonts/Galmuri11.ttf ../assets/fonts/Galmuri11-Bold.ttf ../assets/fonts/LICENSE-OFL.txt "$BUNDLE/Contents/Resources/fonts/"
# 원화 (우리 그림, 비공개 pet/ 저장소): AES 로 잠가 .sprite 로 넣는다. 패키지를 열어도 PNG 가 아니다.
# (스크린샷으로 화면 픽셀을 복원하는 것까지는 막지 못한다 — 그림은 저작권으로 지킨다)
CATS=../pet/assets/original-cat/current
LOCK=../pet/tools/lock_sprites.swift
if [[ -f "$CATS/sit_front.png" && -f "$LOCK" ]]; then
  LOCK_BIN=.build/lock_sprites
  if [[ ! -x "$LOCK_BIN" || "$LOCK" -nt "$LOCK_BIN" ]]; then swiftc -O -o "$LOCK_BIN" "$LOCK"; fi
  "$LOCK_BIN" ../pet/Sources/SpriteKey.swift "$CATS" "$BUNDLE/Contents/Resources/cats/original"
else
  echo "경고: 고양이 원화 없음 (pet/ 비어 있음) → 고양이 없이 번들"
fi
# 팩 그림: 재배포 금지 라이선스라 배포본에는 넣지 않는다
if [[ "${INCLUDE_VENDOR:-}" == 1 ]]; then
  for n in 1 2 3; do
    src="../assets/vendor/lasttick-cats/lt_cat_${n}_64_64_.png"
    [[ $n == 1 && -f ../assets/vendor/lasttick-cats/lt_cat_1_slim.png ]] && src="../assets/vendor/lasttick-cats/lt_cat_1_slim.png"
    [[ -f "$src" ]] && cp "$src" "$BUNDLE/Contents/Resources/cats/cat_${n}.png"
  done
fi
echo "번들: $BUNDLE"
