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

## 맥 상태 (CPU·메모리·발열·에너지·GPU) (2026-10-28)

코드: `collector/Sources/ActLog/ResourceRules.swift`(규칙, 테스트 있음) · `ResourceWatch.swift`(읽기·메뉴·전달) · `ResourceDashboard.swift`(대시보드)

10초마다 읽는다. 관리자 권한은 쓰지 않으므로 다른 사용자·시스템(root) 프로세스는 앱 목록에서 빠진다. 전체 CPU에는 들어간다.

| 값 | 읽는 곳 |
|---|---|
| 전체 CPU | `host_statistics(HOST_CPU_LOAD_INFO)` 두 번 사이의 차이 |
| 앱별 CPU·메모리·전력 | `proc_pid_rusage(RUSAGE_INFO_V6)`: CPU 시간, `ri_phys_footprint`, `ri_energy_nj`. 도우미·터미널에서 돌린 명령은 책임 프로세스(활성 상태 보기와 같은 방식)의 앱으로 묶는다 |
| 메모리 | `kern.memorystatus_level`(남은 %), `kern.memorystatus_vm_pressure_level`(압박 단계), `vm.swapusage` |
| 발열 | `ProcessInfo.thermalState` |
| 배터리 | IOPowerSources(%, 충전 중, 남은 시간, 저전력 모드), AppleSmartBattery 전류×전압(배터리로 쓸 때 전력) |
| GPU | IOAccelerator `PerformanceStatistics`. **따로 단 GPU만**(AMD·NVIDIA·인텔·eGPU). Apple 칩 내장 GPU(AGX…)는 안 본다. 문서에 없는 키라 macOS가 바뀌면 안 나올 수 있다 |

| 알림 | 언제 | 급함 |
|---|---|---|
| 뒤에서 CPU를 많이 씀 | 앞에 없는 앱이 코어 0.9개 넘게 3분 | 아님 |
| CPU 꽉 참 | 전체 85% 이상 2분, 혼자 많이 쓰는 앱은 없고 제일 많이 쓰는 앱이 앞에 없을 때 | 아님 |
| 메모리 빠듯 · 심각 | 압박 단계 warn 1분 · critical 20초 (스왑 크기만으로는 말하지 않는다) | 심각만 |
| 맥이 뜨거움 | thermalState serious 1분 · critical 10초 | critical만 |
| 뒤에서 전기를 많이 먹음 | 배터리로 쓰는 중, 앞에 없는 앱이 2W 넘게 5분 | 아님 |
| 배터리 빨리 닳음 | 남은 시간 1시간 미만인데 25% 넘게 남았을 때 2분 | 아님 |
| 배터리 20% · 10% | 배터리로 쓰는 중 | 10%만 |
| GPU 꽉 참 | 따로 단 GPU 90% 이상 5분, 제일 바쁜 앱이 앞에 없을 때 | 아님 |

- 지금 쓰고 있는 앱 때문이면 말하지 않는다. 게임·빌드·렌더링 중 높은 사용률은 정상이다.
- 조건마다 한 번만 말한다. 30초 안에 잠깐 내려갔다 올라오면 이어진 것으로 본다. 풀렸다가 다시 생겨도 1시간 안에는 다시 말하지 않는다.
- 급하지 않은 알림은 15분에 하나까지.
- 말풍선 위에 마우스를 2초 올려 두면 대시보드 미리보기가 뜬다. 말풍선을 누르거나 미리보기를 누르면 고정된다. 고정된 대시보드는 ×, Esc, 바깥 클릭으로 닫는다.
  대시보드에는 알림이 뜬 이유, CPU·메모리·발열·에너지(·GPU) 막대와 최근 10분 선, 많이 쓰는 앱이 나온다. 앱 목록은 알림 종류에 따라 CPU·메모리·전력 순으로 정렬된다. 떠 있는 동안은 2초마다 새로 읽는다.
- 메뉴 › 🖥️ 맥 상태에서 할 수 있는 것: 지금 값 보기, 대시보드 열기, 알림 끄기, 끈 앱 다시 켜기. 앱별 알림은 대시보드에서 끈다.

### 묘전트가 쓰는 양 (2026-10-30)

대시보드 아래쪽에 묘전트 자신의 CPU·메모리·디스크·네트워크·데이터 폴더 크기가 나온다. 앱 + 브레인(`actlog_brain.py`) + 말하는 고양이(`cat_mind.py`)와 그 자식 프로세스를 합친 값이고, 묶음별 CPU·메모리도 따로 보여 준다.

- CPU·메모리·디스크: `proc_pid_rusage`. 평소 읽기(10초)에 얹어서 메뉴에도 CPU·메모리가 나온다.
- 네트워크: 공개 API가 없어 `nettop -P -d -L 2 -s 5`로 5초씩 재고 다시 띄운다. **대시보드가 떠 있는 동안만** 돌고, 합계도 연 뒤부터다. 그동안 nettop 자신의 CPU도 "앱"에 포함된다 (닫으면 사라진다).
- nettop은 입력이 /dev/null이거나 닫히면 코어 하나를 다 쓰고, pty로 받으면 앱이 죽은 뒤에도 남아 계속 돈다 (2026-10-30 실측). 그래서 열어 둔 파이프를 입력으로 주고, 계속 띄워 두지 않는다.
- 데이터 폴더: 대시보드가 떠 있을 때 1분에 한 번 잰다.

### 앱 정리 (2026-10-30)

코드: `CleanupRules.swift`(판단, 테스트 있음) · `AppCleaner.swift`(실행·메뉴). 잘못 끄면 작업을 잃으므로 묻는 쪽으로 기울어 있다.

| 판단 | 조건 |
|---|---|
| 건드리지 않음 | 보호 목록(시스템·개발 도구·AI·통화·메신저·보안·음악·녹화·원격·네트워크·동기화), 앞에 있는 앱, 지켜본 지 10분 안 된 앱, 평균 CPU 5% 이상(일하는 중), "항상 두기", "이번엔 두기" 3일 |
| 묻기 | 창 없이 6시간 안 씀 / 2시간 안 쓰는데 메모리 1GB 이상 / 메모리 빠듯(압박 warn 이상)한데 2시간 안 쓰고 300MB 이상 / 메뉴바 앱이 메모리 1GB·평균 CPU 30% 이상 |
| 자동 | "앞으로 자동 정리"를 고른 Dock 앱이 창 없이 6시간 안 쓰고 평균 CPU 1% 미만일 때만 |

- 처음 보는 앱은 절대 자동으로 끄지 않는다. 창이 있거나 메뉴바 앱이면 허락했어도 자동이 아니다.
- 끄는 방법은 `terminate()`뿐이다. 저장 안 한 게 있으면 그 앱이 먼저 묻고, 20초 안에 안 꺼지면 그대로 두고 3일 건드리지 않는다. 강제 종료는 없다.
- 창 없는 프로세스(데몬)는 대상이 아니다. launchd가 다시 띄우거나 다른 앱이 깨진다. 많이 쓰면 위 맥 상태 알림으로 알려 준다.
- 묻기는 1시간에 하나까지, 자리에 있을 때만(입력 5분 안). 30분 동안 답이 없으면 끄지 않고 3일 미룬다. 맥 상태 알림을 끄면 묻기도 멈추고, 메뉴에서 정리 제안을 끄면 자동까지 멈춘다.
- 말풍선을 누르면 대시보드에서 고른다: 정리하기 · 앞으로 자동 정리 · 이번엔 두기 · 항상 두기. 메뉴 › 🖥️ 맥 상태 › 🧹 앱 정리에서도 같고, 자동·항상 두기 해제와 최근 정리한 앱 다시 열기도 여기서 한다.
- 시간 기준 조절: `defaults write io.github.jasonwpgml.meowgent cleanupAskIdleHours -float 2`, `cleanupQuietIdleHours`.
- 외부로 보내는 것 없음. 앱별 마지막 사용 시각만 UserDefaults(`cleanupLastUsed`)에 남는다.

## 참고

- CodexBar 알림 설계: 50%/20% 남음, 바닥, 회복, 리셋권 3일 전, 예측 경고는 위험 구간당 한 번 —
  https://github.com/steipete/CodexBar (docs/claude.md, codex.md, cursor.md, grok.md, predictive-pace-warning spec)
- Claude 리셋권: https://support.claude.com/en/articles/17007452-about-limit-resets
- Codex 리셋권(banked resets): 받은 날로부터 30일 뒤 만료되고, 쓰면 5시간 창과 주간 창이 함께 리셋되며 주간 리셋 날짜가 다시 잡힌다 —
  https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work
- Fitz et al. 2019, 알림 묶음 실험: https://scholars.duke.edu/publication/1402953
- Ancker et al. 2017, 반복 경고와 피로: https://pmc.ncbi.nlm.nih.gov/articles/PMC5387195/
