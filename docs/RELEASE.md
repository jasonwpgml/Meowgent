# 배포 절차 (2026-10-21)

소스는 비공개(GitHub private `jasonwpgml/Meowgent`). 사용자는 랜딩 페이지나 public 저장소의 Releases에서 받는다.
빌드 산출물은 `collector/release.sh` → `collector/dist/`.

## 두 가지 길

| | 임시 서명 zip (지금 가능) | Developer ID + 공증 (연 129,000원) |
|---|---|---|
| 명령 | `./release.sh` | `SIGN_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=meowgent ./release.sh` |
| 산출물 | `Meowgent-<버전>-unsigned.zip` | `Meowgent-<버전>.dmg` (공증·스테이플 됨) |
| 받는 쪽 | "Apple이 확인할 수 없음" → 설정 › 개인 정보 보호 및 보안 › "그래도 열기" | 그냥 열림 |
| 권한 | 업데이트마다 손쉬운 사용·입력 모니터링 다시 켜야 함 | 유지됨 |
| 신뢰 | 서명 없는 앱이 입력 모니터링을 요구 → 악성코드처럼 보임 | 정상 |

결정: 첫 공개는 zip으로 내보고, 쓰는 사람이 생기거나 포트폴리오로 쓸 때 Developer ID로 넘어간다. 스크립트는 둘 다 지원하므로 그때 인증서 이름만 넣으면 된다.

## Developer ID 받은 뒤 한 번만
1. developer.apple.com 가입 (개인, Apple ID + 신분 확인, 1~2일).
2. Xcode › Settings › Accounts › Manage Certificates › **Developer ID Application** 만들기. 키체인에 "Developer ID Application: 이름 (TEAMID)"가 생긴다.
3. appleid.apple.com에서 앱 암호 하나 만들고:
   ```bash
   xcrun notarytool store-credentials meowgent --apple-id <애플ID> --team-id <TEAMID> --password <앱 암호>
   ```
4. 이후 배포는 위 표의 명령 한 줄.

## 배포본에 들어가는 것 / 안 들어가는 것
- 들어감: 원화 고양이(`assets/original-cat/current`), 갈무리11 글꼴(OFL), `LICENSES.md`(참고 코드 MIT·0BSD 고지, CC BY 사진 저작자), 앱 아이콘.
- 안 들어감: Last tick 팩 그림(재배포 금지 → 개발 빌드 `INCLUDE_VENDOR=1`에만), brain·Clef·tools(개인용), 심볼(`strip -x`).
- 활동 기록은 옵트인. 처음 실행 때 묻고 기본은 "고양이만".

## 버전 올리기
`collector/Info.plist`의 `CFBundleShortVersionString`(사람용)과 `CFBundleVersion`(정수, 매번 +1)을 같이 올린다.

## 저장소 분리 (2026-10-25)
- 고양이 코드·원화·행동 문서는 비공개 저장소 `meowgent-pet`(이 저장소의 `pet/` 서브모듈). 공개 쪽은 `collector/setup-pet.sh`가 `Sources/ActLog/Pet` 링크를 만들고, 서브모듈이 비어 있으면 `PetStub`으로 빌드된다.
- 원화는 `bundle.sh`가 `pet/tools/lock_sprites.swift`로 AES-GCM 잠금(`.sprite`)해서 넣는다. 키는 `pet/Sources/SpriteKey.swift`. 배포본에 `.png`가 남아 있으면 안 된다: `ls Meowgent.app/Contents/Resources/cats/original | grep png`가 비어야 한다.
- **공개할 때 이력 정리 필수.** 이 저장소의 분리 전 커밋(2026-10-21~25)에는 Pet 소스와 원화가 들어 있다. 공개 저장소는 (a) `brew install git-filter-repo` 후 `git filter-repo --path collector/Sources/ActLog/Pet --path assets/original-cat --path docs/CAT_MOTION.md --path docs/CAT_VOICE.md --invert-paths`를 돌린 사본, 또는 (b) 분리 후 상태를 새 저장소에 첫 커밋으로 올린 것 중 하나로 만든다. 올리기 전에 `git log --all -- assets/original-cat`이 비어 있는지 확인한다.
- `release.sh`는 `pet/`이 없으면 멈춘다 (고양이 없는 배포본은 만들지 않는다).

## 공개 저장소 / 랜딩 페이지 (아직 없음)
- private 저장소의 Releases는 본인만 받을 수 있다. README + Releases만 있는 public 저장소(예: `meowgent-releases`)를 따로 둔다.
- 랜딩 페이지에 `pet/docs/prototype/index.html` 식 웹 데모를 넣으면 설치 전에 보여 줄 수 있다. 진짜 앱은 브라우저에서 못 돌아간다고 적는다.
- 자동 업데이트(Sparkle)는 공증된 DMG가 생긴 뒤에 붙인다. 임시 서명 상태에서는 업데이트마다 권한이 풀려 의미가 적다.

## 체크리스트 (공개 전)
- [ ] 다른 맥(또는 새 사용자 계정)에서 zip 받아 첫 실행 → 동의 창 → "고양이만"으로 기록 안 되는지, 권한 없이도 고양이가 뜨는지
- [ ] 메뉴 › Meowgent 정보 › 라이선스 보기 열리는지
- [ ] brain·Clef 없는 맥에서 고양이 말풍선·사용량 메뉴가 "없음"으로 조용히 넘어가는지
- [ ] public 저장소 README에 "무엇을 기록하나 / 안 하나" 표 그대로 싣기
