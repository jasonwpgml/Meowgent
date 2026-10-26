# 한도·리셋권 리마인드 (2026-10-17)

냥전트가 "놓치고 있는 것"을 대신 챙긴다. 사용 한도가 남은 채로 리셋되거나, 리셋권이 안 쓴 채로 만료되는 경우다.
코드: `collector/Sources/ActLog/Pet/QuotaRules.swift`(규칙, 테스트 있음) · `QuotaWatch.swift`(읽기·메뉴·전달)

## 어디서 읽나 (토큰·쿠키는 안 읽음, 외부로 보내는 것 없음)

| 대상 | 파일 | 내용 |
|---|---|---|
| Claude · Cursor · Grok · Grok Bot | `~/Library/Group Containers/Y5PE65HELJ.com.steipete.codexbar/widget-snapshot.json` | CodexBar가 남기는 창별 사용률·리셋 시각 (ISO 시각) |
| Codex (계정별) + **Codex 리셋권** | `~/Library/Application Support/CodexBar/codex-account-snapshots.json` | `primary/secondary` 창, `codexResetCredits.credits[]` (`expires_at`, `status`). 시각은 2001-01-01 기준 초 |
| Codex (CodexBar 값이 없을 때) | `~/.codex/sessions/**/rollout-*.jsonl` | `rate_limits.primary/secondary` (AgentMonitor) |
| Claude 리셋권 등 위 파일에 없는 것 | `~/Library/Application Support/ActLog/reset_passes.json` | 고양이 메뉴 › ⏳ 한도·리셋권 › "리셋권 직접 적기…" |

CodexBar는 Claude "Limit resets"와 Grok 리셋권을 메모리에만 들고 있어서 파일로는 못 읽는다.
그래서 이 둘은 직접 적어 두는 방식으로 받는다. Claude는 설정 › 사용량 › 리셋에서 만료일을 볼 수 있다. 사용은 웹이나 데스크톱 앱에서만 된다.

## 알림 규칙

| 종류 | 언제 | 급함 |
|---|---|---|
| 바닥난다 | 주간·월 창: 80 / 90 / 95 / 100%. 5시간 창: 90 / 100%. 그 창의 가장 높은 단계만, 한 번씩. 90% 이상이면 리셋권 개수도 같이 | 90% 이상 |
| 이 속도면 바닥 | 창의 30% 이상이 지났고, 평균 속도로 가면 리셋 12시간 전보다 먼저 100%가 될 때. 창마다 한 번 | 아님 |
| 남는다 (안 쓰면 사라짐) | 주간: 리셋 24시간 전인데 40% 넘게 남음, 6시간 전인데 25% 넘게 남음. 월: 3일 전 50%, 1일 전 30%. 이번 창에 손도 안 댄 서비스는 하루 전 알림만 | 아님 |
| 다시 채워짐 | 80% 넘게 쓰던 창이 리셋됐을 때 | 아님 |
| 리셋권 만료 | 7일 · 3일 · 하루 · 3시간 전. 같은 계정의 주간 사용률이 30% 이상이면 "지금 쓰면 그만큼 돌려받는다"고 조언 | 하루 안 |
| 리셋권 새로 받음 | 받은 지 3일 안 | 아님 |
| 오늘 챙길 것 | 하루 한 번, 아침 7시 이후 처음 볼 때. 주간·월 창의 남은 양, 하루 권장량 또는 바닥 예상 시각, 리셋권 개수와 가장 빠른 만료 | 아님 |

## 피로 줄이기

- 알림마다 키를 정해서(계정 + 창 + 리셋 시각 + 단계) 딱 한 번만 말한다. 키는 40일 동안 보관하고, 앱을 다시 켜도 유지된다.
  반복 알림은 한 번 늘 때마다 반응률이 약 30%씩 떨어진다 (Ancker et al. 2017).
- 급하지 않은 알림은 30분에 한 번까지, 한 번에 세 개까지만 보낸다. 브리핑을 보낸 날은 같은 내용을 따로 말하지 않는다.
  알림을 모아서 보내면 주의력과 스트레스가 나아진다. 다만 아예 끄면 오히려 불안이 늘었다 (Fitz et al. 2019).
- 데이터가 6시간 넘게 오래됐으면 사용률 기반 알림은 하지 않는다. 리셋권 만료는 날짜가 정해져 있으므로 알리되, "(10/12 기준)"을 붙인다.
- 말풍선에 유효 시각을 둔다. 자리를 비운 사이에 "30분 뒤 리셋"이 지나 버리면 그 알림은 버린다.
- 메뉴에서 할 수 있는 것:
  - "오늘은 급한 것만": 다음 날 아침 7시까지 적용된다.
  - 에이전트별로 끄기.
  - "오늘 챙길 것 다시 보기".

## 참고

- CodexBar 알림 설계: 50%/20% 남음, 바닥, 회복, 리셋권 3일 전, 예측 경고는 위험 구간당 한 번 —
  https://github.com/steipete/CodexBar (docs/claude.md, codex.md, cursor.md, grok.md, predictive-pace-warning spec)
- Claude 리셋권: https://support.claude.com/en/articles/17007452-about-limit-resets
- Codex 리셋권(banked resets): 받은 날로부터 30일 뒤 만료되고, 쓰면 5시간 창과 주간 창이 함께 리셋되며 주간 리셋 날짜가 다시 잡힌다 —
  https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work
- Fitz et al. 2019, 알림 묶음 실험: https://scholars.duke.edu/publication/1402953
- Ancker et al. 2017, 반복 경고와 피로: https://pmc.ncbi.nlm.nih.gov/articles/PMC5387195/
