# 메뉴바 고양이 손 아이콘

메뉴바에 뜨는 고양이 손(`collector/Resources/MenuBarPaw*.png`)을 만든 방법.
사진의 픽셀은 넣지 않았다. 손 외곽과 젤리 모양만 사진에서 따서 새로 그렸다.

## 참고한 사진

| 사진 | 쓴 곳 | 출처 |
|---|---|---|
| 들어 올린 고양이 손바닥 (회색 줄무늬, 검은 젤리) | 손 외곽 (Vision으로 분리), 젤리 자리 | Sebastian Schuster, Unsplash — https://unsplash.com/photos/close-up-of-a-cats-fluffy-paw-with-visible-beans-WN3GIqbTHa4 (Unsplash License) |
| 분홍 젤리 고양이 손바닥 클로즈업 | 젤리 모양 (발가락이 위아래로 긴 것, 큰 젤리 세 갈래) | 사용자가 대화에 붙인 사진 (출처 모름). 눈으로 잰 숫자만 썼다 |

## 만드는 순서

1. 첫 사진을 받는다 (1400px 폭이면 좌표가 그대로 맞는다).
   `curl -L -o paw.jpg "https://images.unsplash.com/photo-1774835534185-ae856f175f30?fm=jpg&q=80&w=1400"`
2. Vision으로 고양이를 분리한다: `swiftc -O -o mask mask.swift && ./mask paw.jpg .` → `mask_1.png`
3. 아이콘을 만든다: `swiftc -O -o make make.swift && ./make paw.jpg mask_1.png out`
   - `MIX` 환경 변수: 0 = 첫 사진 젤리만, 1 = 두 번째 사진 젤리. 메뉴바에 넣은 것은 0.8 (기본값).
   - 손 외곽: 오목한 곳 메우기 → 삐친 털 깎기 → 손목은 곧은 두 변 → 젤리 둘레에 털 테두리 남기기.
4. `out/paw_18.png`, `paw_36.png`, `paw_54.png`를 `collector/Resources/MenuBarPaw.png`, `@2x`, `@3x`로 복사한다.

`paw_full.png`는 줄이기 전 큰 그림이다.
