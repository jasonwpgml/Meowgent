# Meowgent 윈도우 이식 설계 (2026-10-21)

맥 전용 Swift 앱(수집기 ActLog + 화면 위 고양이)을 윈도우 데스크톱(CUDA GPU 있음)과 삼성 노트북(GPU 없을 가능성 높음)에서도 쓰기 위한 설계 문서다.
코드는 아직 없다. 이 문서는 (1) 맥 모듈마다 윈도우에서 무엇으로 바꾸는지, (2) 어떤 스택으로 만들지, (3) 1단계에서 무엇까지 만들지, (4) 두 OS가 무엇을 공유하는지를 정한다.

근거 표시: ✅ 문서·코드로 확인한 것 · 🔸 경험·자료 기반 추정(측정 전) · ❓ 만들기 전에 확인해야 하는 것.
맥 쪽 줄 수는 2026-10-21 기준 `wc -l` 값이다 (수집기 약 2,400줄 — 단축키 코치 472줄 포함, Pet 약 5,300줄, brain 724줄).

## 0. 결론 먼저

- **스택: C#/.NET 8, Win32 + Direct2D(또는 UpdateLayeredWindow) 직접 호출, NativeAOT 단일 exe.** WPF·WinUI·웹뷰는 오버레이에 쓰지 않는다. 메모 입력창 같은 대화상자만 WPF 없이 Win32 대화상자로. 근거는 §2.
- **맥 Swift는 그대로 둔다.** 윈도우는 두 번째 네이티브 클라이언트다. 행동 코드는 두 벌이 되지만, 순수 로직(프라이버시 규칙·한도 규칙·그림 규칙·날짜 해석)은 `shared/`에 데이터와 테스트 벡터로 빼서 한 벌로 맞춘다 (§4).
- **1단계는 고양이만**: 오버레이 + 창 윗변 지형 + 키 입력 반응 + AgentMonitor + 알림 말풍선 + 메모. 맥 코드 기준 약 3,300줄, C#로 3,000~4,500줄 🔸. 수집기·brain·Clef 는 2단계 이후 (§3).
- **윈도우가 맥보다 쉬운 것**: 권한 창(TCC)이 없고, 창 목록·클릭 통과·화면 공유 제외·클립보드 알림이 전부 공개 API다. **어려운 것**: 브라우저 주소(AppleScript 없음), CodexBar 없음, 한글 IME 조합 중 글자, 가상 데스크톱 번호(비공개 COM), 관리자 권한 창은 안 보임(UIPI).

---

## 1. 모듈 대응표

### 1.1 수집기 (collector/Sources/ActLog, 약 2,400줄)

| 맥 파일 (줄) | 맥에서 쓰는 API | 윈도우 대응 | 메모 |
|---|---|---|---|
| `main.swift` (288) | `NSStatusItem` 메뉴바, `AXIsProcessTrustedWithOptions`·`CGPreflightListenEventAccess` 권한 요청, `.accessory` 정책, 인스턴스 정리 | 트레이 아이콘 `Shell_NotifyIcon`(NotifyIcon) + 팝업 메뉴 `TrackPopupMenuEx`. 권한 요청 코드 전부 삭제 (손쉬운 사용·입력 모니터링 권한이 없다 ✅). 단일 인스턴스는 named mutex | 상태 아이콘 ◉◎◌ 3종은 16×16 아이콘 3장으로. 권한 상태 줄은 "관리자 창 감지 불가" 안내로 바뀐다 |
| `AppWatcher.swift` (137) | `NSWorkspace.didActivateApplication`, `AXObserver`(FocusedWindow·Title·FocusedUIElement·Value·MainWindow 변경), Electron에 `AXManualAccessibility` 켜기 | `SetWinEventHook(WINEVENT_OUTOFCONTEXT)`: `EVENT_SYSTEM_FOREGROUND`(앱 전환), `EVENT_OBJECT_NAMECHANGE`(창 제목), `EVENT_OBJECT_FOCUS`(입력창 이동), `EVENT_OBJECT_VALUECHANGE`(값) ✅. 앱 이름은 `GetWindowThreadProcessId` → `QueryFullProcessImageName`(exe 경로) ✅ | 창 제목 debounce 0.4초 그대로. Chromium/Electron 은 UIA 클라이언트가 붙으면 스스로 접근성을 켜므로 `AXManualAccessibility` 대응 불필요 ✅. 번들 ID 자리에 exe 이름(`Code.exe`)과 패키지 앱은 `GetApplicationUserModelId` 🔸 |
| `AX.swift` (89) | `AXUIElementCopyAttributeValue`(Title·Description·Placeholder·Help·Value·Role·Children·Identifier), `IsAttributeSettable`, `AXUIElementGetPid` | `IUIAutomation`(COM, `UIAutomationClient`): `Name`·`HelpText`·`ControlType`·`AutomationId`·`ProcessId`, `ValuePattern.Value`, `LegacyIAccessible.Description`, `TreeWalker`로 자식. 비밀번호 칸은 `IsPassword` 속성 ✅ | 맥은 `AXUIElementSetMessagingTimeout(0.5초)`. UIA는 `IUIAutomation2.ConnectionTimeout`/`TransactionTimeout`(Win8+) ✅. **속성은 캐시 요청(`CacheRequest`)으로 한 번에 받아야** 왕복 수가 줄어든다 — 맥보다 cross-process 호출이 비싸다 🔸 |
| `TextCapture.swift` (234) | 포커스 입력창의 `AXValue`를 Enter·포커스 이동·8초 정지 때 읽어 직전 값과 diff. `AXNumberOfCharacters`로 큰 문서 제외. 자모 1~2자 꼬리 버림 | `ValuePattern.CurrentValue`, 없으면 `TextPattern.DocumentRange.GetText(maxLength)` — **maxLength 가 있어 큰 문서 가드가 공짜** ✅. diff·커밋 규칙은 그대로 | 한글 IME 처리는 §1.4 |
| `BrowserWatcher.swift` (162) | `NSAppleScript`로 앞 탭 URL·제목·시크릿 여부, Apple Events 권한 | **대응 없음.** 대안 ①: UIA로 주소창 Edit 컨트롤 값 읽기(Chrome·Edge·Whale·Brave 공통 구조, Firefox 별도) 🔸 ②: 브라우저 확장 + Native Messaging(`HKCU\Software\Google\Chrome\NativeMessagingHosts`) ✅ | ①은 주소창 값에 `https://`가 빠질 수 있고(🔸), 주소창을 편집 중이면 입력 중 글자가 읽힌다 → 2단계는 ①로 시작, 정확도가 필요하면 ②. 시크릿 창은 창 제목 꼬리 "(Incognito)"/"(시크릿 모드)"로 판별 🔸. Safari 는 없음 |
| `InputTap.swift` (190) — `InputTap` | `CGEventTap`(listen-only, 세션 전체): 키 횟수·Enter·⌘V·⌘/⌃ 조합, 클릭 위치, 스크롤, 마우스 이동 거리. 탭이 느리면 OS가 끈다(`tapDisabledByTimeout`) | **Raw Input**(`RegisterRawInputDevices`, `RIDEV_INPUTSINK`) 권장 ✅: 메시지 루프로 받고 시간 제한이 없다. 마우스 이동은 상대 좌표라 거리 계산이 바로 된다. 대안 `WH_KEYBOARD_LL`/`WH_MOUSE_LL`: 콜백이 `LowLevelHooksTimeout`(수백 ms)을 넘기면 **조용히** 제거된다 ✅ — 맥처럼 알려 주지 않으니 주기적으로 재설치 필요 | Enter = `VK_RETURN`, 붙여넣기 = Ctrl+`V` 와 Shift+Insert. ⌘ 조합 → Ctrl 조합. 한/영(`VK_HANGUL`)·한자(`VK_HANJA`)는 횟수엔 넣되 조합 판정에서 뺀다. **관리자 권한 창에 입력 중이면 LL 훅은 못 본다(UIPI)** ✅, Raw Input 도 같은지 ❓ |
| `InputTap.swift` — `ClickResolver` | `AXUIElementCopyElementAtPosition` → 부모를 6단계 올라가며 누를 수 있는 역할 찾기, 메뉴 항목의 `AXMenuItemCmdChar`(단축키) | `IUIAutomation.ElementFromPoint`(캐시 요청과 함께) → `TreeWalker.GetParent`. 역할 표: Button·Hyperlink·MenuItem·CheckBox·RadioButton·ComboBox·TabItem·ListItem·TreeItem·Edit·Document… 단축키는 `AcceleratorKey`/`AccessKey` 속성 ✅ (Win32 메뉴만 채워지고 Electron·웹 메뉴는 대개 빈 값 🔸) | Dock 항목 → 작업 표시줄 버튼. 자기 메뉴 클릭 제외는 `ProcessId == 내 pid` |
| `SystemWatcher.swift` (162) | `CGEventSource.secondsSinceLastEventType`(유휴), `com.apple.screenIsLocked`, `NSWorkspace.willSleep/didWake`, `NSPasteboard.changeCount` 1초 폴링, nspasteboard.org 숨김 타입, `IsSecureEventInputEnabled` | 유휴: `GetLastInputInfo` ✅ (훅 없이 됨, 49.7일 넘어가면 tick 되감김 처리). 잠금: `WTSRegisterSessionNotification` + `WM_WTSSESSION_CHANGE`(`WTS_SESSION_LOCK/UNLOCK`) ✅. 잠자기: `WM_POWERBROADCAST`(`PBT_APMSUSPEND`, `PBT_APMRESUMEAUTOMATIC`) ✅. 클립보드: `AddClipboardFormatListener` + `WM_CLIPBOARDUPDATE` — **폴링 불필요** ✅. 숨김 표시: 클립보드 포맷 `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory=0`, `CanUploadToCloudClipboard=0` ✅ (1Password·Bitwarden·KeePass 윈도우판이 씀 🔸) | **보안 입력 감지는 불필요** (윈도우엔 해당 개념이 없다; 비밀번호 칸은 UIA `IsPassword`로 내용만 안 읽으면 된다). `health` 이벤트의 권한 항목은 "훅 살아 있음"·"UIA 연결됨"으로 바꾼다 |
| `Context.swift` (284) | 순수 로직: `Config`, `Privacy`(차단 번들·도메인, URL 파라미터 가리기, 정규식 9종 + Luhn, AI 사이트 판별, 검색어 추출) | 1:1 이식. `NSRegularExpression` → .NET `Regex`(같은 문법). **차단 앱 목록만 OS별**: 1Password.exe·Bitwarden.exe·KeePass.exe·KeePassXC.exe, 터미널 WindowsTerminal.exe·cmd.exe·powershell.exe·pwsh.exe·wezterm-gui.exe·alacritty.exe, 편집기 Code.exe·Cursor.exe·idea64.exe·pycharm64.exe·Obsidian.exe·WINWORD.EXE·notepad.exe 🔸 | 도메인·정규식·검색 규칙은 `shared/privacy_rules.json`으로 빼고 두 OS가 읽는다 (§4). 번들 ID 키는 `{"mac": "...", "win": "..."}` 쌍으로 |
| `Store.swift` (145) | sqlite3 C API, WAL, `chmod 0600`, `clock_gettime(CLOCK_UPTIME_RAW)` | `Microsoft.Data.Sqlite`(또는 sqlite3 C API P/Invoke). 스키마 동일. 경로 `%LOCALAPPDATA%\ActLog\actlog.db` (Roaming 아님 — DB가 크다). 권한은 `%LOCALAPPDATA%` ACL 상속(본인만) ✅. 단조 시계 `QueryPerformanceCounter`/`Stopwatch.GetTimestamp` | `mono` 컬럼은 ns 단위 유지. 저널 큐는 전용 스레드 하나 |
| `AIResponseCapture.swift` (159) | `AXWebArea` 찾기, `AXTextMarkerRange`로 페이지 글 한 번에, 안 되면 `AXStaticText` 8,000개 트리 순회 | Chromium 은 웹 내용을 `ControlType.Document`로 노출하고 `TextPattern.DocumentRange.GetText(-1)`로 **페이지 글 전체를 한 번에** 준다 ✅. 폴백 트리 순회는 `TreeWalker` + 캐시 요청 | 2초 폴링·4초 안정 판정·240초 상한은 그대로. Document 하나당 GetText 비용 수십 ms 🔸 |
| `LaunchAgent.swift` (62) | launchd plist: `RunAtLoad`, `KeepAlive(SuccessfulExit: false)`, 종료코드 75로 재시작 | 로그인 실행: `HKCU\...\Run` 키 또는 작업 스케줄러 `ONLOGON`. 죽으면 재시작: 작업 스케줄러 "실패 시 N분마다 다시 시작" 설정 ✅ (Run 키엔 없음). 메뉴의 "다시 시작"은 자기 exe를 `Process.Start`한 뒤 종료 | 작업 스케줄러 쪽을 기본으로. 설치 스크립트 `win/install.ps1`(`schtasks /create /sc onlogon /rl limited`) |
| `ShortcutCoach.swift`+`ShortcutRules.swift` (472) | `kAXMenuBarAttribute` 메뉴 막대 순회, 메뉴 항목 단축키 읽기, 창 단추·Dock·Mission Control 고정 규칙, ⌃⌥⇧⌘ 표기 | UIA `MenuBar`/`MenuItem` + `AcceleratorKey` (Win32 앱만; VS Code·Electron 은 HTML 메뉴라 부분 🔸). 고정 규칙은 OS별 표: 닫기 ⌘W→Ctrl+W/Alt+F4, 최소화 ⌘M→Win+↓, Dock→작업 표시줄 Win+1~9, Mission Control→작업 보기 Win+Tab, ⌃1~9→Win+Ctrl+←/→ | 2.5단계. `shortcuts.json` 구조는 공유, 규칙 표만 `shared/shortcut_rules.{mac,win}.json` |
| `NSMenu+Item.swift` (12) | 메뉴 헬퍼 | 메뉴 빌더 헬퍼 | — |

### 1.2 고양이 (collector/Sources/ActLog/Pet, 약 5,300줄)

| 맥 파일 (줄) | 맥에서 쓰는 API | 윈도우 대응 | 메모 |
|---|---|---|---|
| `PetController.swift` (733) — 패널·틱 | `NSPanel(.nonactivatingPanel, .borderless)`, `level = .floating`, `collectionBehavior`, `ignoresMouseEvents` 토글, `sharingType`, `CADisplayLink`(30/60Hz 가변, 쉴 때 `isPaused`), `NSEvent.addGlobalMonitor(.mouseMoved)`, `NSScreen`, `didChangeScreenParameters` | 창 스타일 `WS_POPUP` + `WS_EX_LAYERED \| WS_EX_TOOLWINDOW \| WS_EX_NOACTIVATE \| WS_EX_TOPMOST`, `UpdateLayeredWindow`로 32bpp premultiplied DIB 올리기 ✅. **클릭 통과는 공짜**: 레이어드 창은 알파 0 픽셀에서 마우스 메시지가 아래 창으로 통과한다 ✅ → `ignoresMouseEvents` 토글 코드가 없어진다. 마우스가 고양이 근처인지는 `GetCursorPos`를 tick 에서 읽는다(전역 모니터 불필요). 프레임 박자: `DwmFlush` 또는 `DCompositionWaitForCompositorClock`(Win10 2004+), 간단히는 `CreateWaitableTimerEx(CREATE_WAITABLE_TIMER_HIGH_RESOLUTION)` 30Hz ✅. 쉴 때는 타이머 정지. 화면: `EnumDisplayMonitors`·`GetMonitorInfo`(`rcWork` = `visibleFrame`), `WM_DISPLAYCHANGE` ✅ | **Per-Monitor DPI v2 필수** (아니면 OS가 창을 흐리게 키운다) ✅. `timeBeginPeriod(1)`은 쓰지 않는다 (전원 소모). 데스크탑은 모니터가 여럿일 가능성 → 1단계는 주 모니터만 (맥도 `screens.first`) |
| `PetController.swift` — 화면 공유 숨김 | `sharingType = .none` (믿지 않음, RESEARCH.md) + 맨 앞 창이 화면 98.5% 덮으면 숨김 | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`(Win10 2004+) ✅ — 맥과 달리 실제로 캡처에서 빠진다. 전체 화면 판정은 `SHQueryUserNotificationState`(`QUNS_RUNNING_D3D_FULL_SCREEN`·`QUNS_PRESENTATION_MODE`) ✅ + 창 덮임 검사 | `WDA_EXCLUDEFROMCAPTURE`가 `WS_EX_LAYERED` 창에서 제대로 동작하는지 ❓ (일부 버전에서 레이어드 창은 검게 나온 보고가 있다) |
| `PetTerrain.swift` (123) | `CGWindowListCopyWindowInfo`(화면에 있는 창, layer 0, alpha, bounds, owner pid, window number) → 창 윗변 발판·옆면 벽·가림 구간 | `EnumWindows`(위→아래 Z 순서) + `IsWindowVisible` + `IsIconic` 제외 + `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`(보이지 않는 테두리 제외) + `DWMWA_CLOAKED`(다른 가상 데스크톱·숨은 UWP 제외) + `WS_EX_TOOLWINDOW` 제외 ✅. 창 ID = HWND | **맥보다 싸다**: 창 200개 열거 + DWM 조회가 1ms 안쪽 🔸 (맥은 `CGWindowList`가 CPU 프로파일 상위, cpu-reduction.md). 더 아끼려면 `SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE·SHOW·HIDE·DESTROY, MINIMIZESTART/END)`로 바뀔 때만 재스캔. 최대화 창은 모니터 밖으로 테두리가 삐져나오니 작업 영역으로 자른다 |
| `PetController+Motion.swift` (411) | 순수 물리·상태 기계 (`rescan`만 지형 재스캔) | 1:1 이식 | 좌표계만 주의: 맥은 왼쪽 아래 원점, 윈도우는 왼쪽 위 원점. 지형 스캔 단계에서 y 를 뒤집어 넣으면 나머지는 그대로 |
| `PetSpaces.swift` (20) | 비공개 `CGSCopyManagedDisplaySpaces`(dlsym)로 데스크톱 번호·개수 | 공개 COM `IVirtualDesktopManager`: `IsWindowOnCurrentVirtualDesktop`, `GetWindowDesktopId`, `MoveWindowToDesktop` ✅. **번호·개수는 공개 API에 없다** (비공개 `IVirtualDesktopManagerInternal`은 빌드마다 IID 가 바뀌어 맥 dlsym 보다 더 깨지기 쉽다 ✅) | 따라가기는 된다: 앞 창의 데스크톱 ID 가 바뀌면 `MoveWindowToDesktop(고양이 창)`. 들어오는 방향(왼/오른쪽)은 모르니 1단계는 오른쪽 고정 또는 무작위. 사용자가 작업 보기에서 "모든 데스크톱에 표시"를 켜면 맥의 `canJoinAllSpaces`와 같다 |
| `PetHand.swift` (77) | 커서 바꾸기 + 비공개 `CGSSetConnectionProperty(SetsCursorInBackground)` | 자기 창 위에 마우스가 있으면 `WM_SETCURSOR`에서 `SetCursor` — 백그라운드 앱도 됨 ✅, 비공개 API 불필요. 커서 생성 `CreateIconIndirect`(핫스팟 포함) | — |
| `PetController+Draw.swift` (280) | `CALayer.contents`/`frame`, `CATransaction`, `magnificationFilter = .nearest`, `NSTextField` 말풍선, `CTFontManagerRegisterFontsForURL`(갈무리·원티드 산스) | 한 프레임을 32bpp 버퍼에 직접 합성(고양이·소품·z·안경·손) → `UpdateLayeredWindow` 한 번. 확대는 nearest(정수 배). 글자: DirectWrite(`IDWriteFactory` + 앱 전용 폰트 컬렉션 `AddFontFile`) 또는 GDI+ `PrivateFontCollection` ✅. 한글 기본 글꼴 맑은 고딕, 픽셀 글꼴 갈무리(OFL)는 동봉 | 맥의 "바뀐 것만 CATransaction" 최적화에 대응하는 것은 "바뀐 프레임만 `UpdateLayeredWindow`"다. Direct2D + DirectComposition 으로 가면 GPU 합성이지만 알파 0 클릭 통과가 사라져 `WM_NCHITTEST`로 직접 해야 한다 → 1단계는 `UpdateLayeredWindow` |
| `PetController+Mouse.swift` (175) | hover(전역 모니터), drag(패널 좌표), 쓰다듬기 | `WM_MOUSEMOVE`/`WM_LBUTTONDOWN`/`SetCapture`. hover 는 알파>0 픽셀 위에서만 오므로 `catRect` 검사 대신 픽셀 알파 그대로 | — |
| `PetController+Menu.swift` (218) | `NSMenu.popUp`, `NSAlert` + `NSTextField` 메모 입력, 앞 앱 복원 | `TrackPopupMenuEx`(`WM_CONTEXTMENU`). 메모 입력은 작은 Win32 대화상자(`DialogBoxIndirect`) — 포커스를 가져갔다 돌려주는 건 `SetForegroundWindow` 제한(마지막 입력을 받은 프로세스만 허용 ✅; 고양이를 클릭했으니 허용됨) | Win32 메뉴의 이모지는 흑백으로 나올 수 있다 🔸 → 메뉴 글자에서 이모지 빼기 |
| `PetController+Notices.swift` (59) | 알림 큐·간격 규칙, `memos.jsonl` 읽기 | 1:1 이식 | — |
| `PetStatus.swift` (131) — `PetJournal.detectDate` | `NSDataDetector`(한국어 날짜 인식) + 정규식 보완 | **대응 없음.** .NET `DateTime.TryParse`는 "내일 오후 3시"를 못 읽는다 → 직접 파서 (내일·모레·글피·다음주 X요일·N일/시간/분 후·오전/오후 N시·M/D) 약 100줄 🔸 | 맥도 `NSDataDetector`가 "3일 후"·"이번 주 금요일"을 틀리니(RESEARCH.md §5) **같은 파서를 두 OS에 두고 `shared/date_parse_vectors.json`으로 맞춘다** |
| `PetStatus.swift` — `PetStatusReader` | sqlite 읽기 전용으로 brain.db | 동일 | brain 이 없으면 `contextLine` 폴백 ("판단기는 꺼져 있다") — 이미 있는 경로 |
| `PetController+Routine.swift` (198) | `Calendar`, `UserDefaults`, Spaces 전환 처리 | `DateTime`/`TimeZoneInfo`, 설정은 `%LOCALAPPDATA%\ActLog\settings.json`(레지스트리 대신, 두 OS 설정 키 이름 통일) | 1.5단계 |
| `PetLife.swift` (518) | 창문·햇살·나비·상자·선물, Open-Meteo `URLSession`(30분, 좌표 소수 1자리), 일출·일몰 계산 | `HttpClient` 한 번 호출. 나머지 순수 | 1.5단계 |
| `PetController+Play.swift` (289), `PetToys.swift` (331), `PetProps.swift` (283), `PetMood.swift` (43) | 순수 로직 + `CGImage` 픽셀 그리기 | 1:1 이식 | 1.5단계 |
| `PetSprites.swift` (329), `PixelArt.swift` (45) | `CGImageSource` PNG 읽기, `CGContext`로 미러·회전·테두리(rim)·보행(gait) 측정 | PNG 읽기 WIC(`IWICImagingFactory`) → RGBA 바이트 배열. 미러·회전·rim·gait 는 바이트 루프로 1:1 | 그림 규칙(칸 64/128px, 발 기준선 49, 보행 측정)은 §4 공유 항목 |
| `PetThought.swift` (97) | `NSView.draw`로 구름 풍선 | 같은 도형을 프레임 버퍼에 그리기(Direct2D `PathGeometry` 또는 GDI+) | — |
| `AgentMonitor.swift` (282) | `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/rollout-*.jsonl` 꼬리 읽기(offset 기억, 30초 폴더 캐시), 6초 폴링 | **경로 같음**: `%USERPROFILE%\.claude\projects`, `%USERPROFILE%\.codex\sessions` ✅. 파일은 Claude Code(node)가 쓰는 중이므로 `FileShare.ReadWrite \| Delete`로 열어야 공유 위반이 안 난다 ✅. 선택: `ReadDirectoryChangesW`(FileSystemWatcher)로 폴링 대체 | 앞 앱 판정 문자열: "anthropic" → `Claude.exe`, 터미널 → `WindowsTerminal.exe`·`Code.exe`·`cursor.exe`. Claude 프로젝트 폴더 이름이 윈도우에선 `C--Users-...` 꼴 🔸 — `claudeTitle`의 마지막 `-` 조각 규칙은 그대로 통함 |
| `QuotaWatch.swift` (393) | CodexBar 파일 2개(Claude·Cursor·Grok·Codex 계정별·리셋권) + Codex 세션 폴백 + 직접 적은 리셋권 | **CodexBar 는 맥 전용** → 윈도우에선 **Codex 세션 `rate_limits` 폴백과 `reset_passes.json` 만 가능**. Claude 한도는 로컬 파일이 없다 (CodexBar 는 Claude 의 OAuth 토큰으로 사용량 API 를 부른다; Meowgent 는 토큰을 읽지 않는 원칙이라 **기본은 안 함**, 2단계 이후 선택) | 메뉴 문구 "읽은 값 없다 (CodexBar부터 켜 둬)" → "Codex 세션 값만 본다. Claude 는 직접 적어 둬" |
| `QuotaRules.swift` (247) | 순수 규칙 (테스트 있음) | 1:1 이식 | `shared/quota_vectors.json`으로 두 구현을 같은 입력·출력으로 검사 (§4) |

### 1.3 brain (brain/actlog_brain.py, 724줄)

| 항목 | 맥 | 윈도우 | 메모 |
|---|---|---|---|
| 언어·의존성 | Python 3 표준 라이브러리 | 동일. 데스크탑엔 이미 Python 이 있다 (AND 프로젝트) | 노트북은 Python 설치가 추가 단계 |
| 데이터 경로 | `~/Library/Application Support/ActLog` | `%LOCALAPPDATA%\ActLog` | 경로 함수 하나로 분기 (약 10줄). sqlite URI 는 `file:///C:/...` 꼴 |
| 상시 실행 | launchd `com.jason.actlog.brain`(KeepAlive, Nice 5) | 작업 스케줄러 ONLOGON + 실패 시 재시작, 우선순위 낮음(`BELOW_NORMAL_PRIORITY_CLASS`) | `brain/install.ps1` 추가 |
| Clef | llama-server `/v1/systemone` (localhost:8010) | **CUDA 데스크탑에서만 선택 설치** (llama.cpp CUDA 빌드 + Clef 모델). 노트북은 Clef 없이 — 지금 코드는 Clef 실패 시 30초마다 재시도만 하고 구간 나누기·타임라인은 계속 쓴다 ✅ → "판단 없는 brain" 모드로 그대로 쓸 수 있다 | `brain.json`에 `"clef_url": null`이면 아예 안 묻게 하는 한 줄 추가 |
| 프로젝트 목록·활동 분류 | `projects.json` | 동일 파일 (맥 것을 복사하거나 위키 동기화로) | — |

### 1.4 한글 IME 입력을 UIA 로 읽을 때 (조합 중 글자)

맥 코드는 키에서 글자를 복원하지 않고 **입력창 값의 diff** 로 글을 얻는다 (TextCapture.swift). 윈도우도 같은 방식이 맞다. 다른 점:

| 상황 | 맥 (AX) | 윈도우 (UIA) | 처리 |
|---|---|---|---|
| 조합 중 글자가 값에 보이나 | 보인다 ("안녕하ㅅ") | MS 한글 IME 는 인라인 조합이라 `ValuePattern`/`TextPattern` 값에 조합 중 음절이 그대로 보인다 ✅ (Win32 Edit·RichEdit·UWP·Chromium·Electron). IMM32 조합창을 쓰는 옛 앱은 확정 때만 값이 바뀐다 | 커밋 시점이 Enter·포커스 이동·정지라서 중간 값은 어차피 안 쓴다. 정지 커밋(8초)만 조합 중 음절을 잡을 수 있다 → **정지 커밋 직전에 0.3초 더 기다렸다 값이 그대로면 커밋** |
| 입력창을 떠날 때 꼬리 자모 | 앱이 조합 중 자모를 버리기도 함 → 맥은 자모 1~2자만 남으면 버림 (U+3130~318F) | 윈도우 IME 는 포커스가 빠질 때 조합을 **확정**해 값에 넣는 것이 보통 ✅ → 꼬리 자모가 남는 경우가 드물다 | 같은 규칙을 두되 범위를 넓힌다: 호환 자모 U+3131~318E + 한글 자모 U+1100~11FF |
| Enter 를 IME 가 먹는가 | — | MS 한글 IME 는 조합 중 Enter 에 조합을 확정하고 Enter 도 앱에 전달한다 🔸 (일본어·중국어 IME 는 Enter 를 "확정"으로 먹는다 ✅). LL 훅/Raw Input 은 IME 번역 전 `VK_RETURN`을 본다 ✅ | 맥처럼 Enter 직후 값을 다시 읽어 새 글이 있으면 그 값으로 커밋. Enter 가 확정에만 쓰여 입력창이 비지 않고 값이 1자 이내로만 바뀌었으면 커밋하지 않는다 (일본어 IME 대비, 설계 제안) |
| 조합 범위를 직접 아는 방법 | 없음 | Win10 UIA `TextEditPattern`의 `ConversionTarget` 범위 + `TextEdit_ConversionTargetChanged` 이벤트 ✅ (Win32·UWP 텍스트 컨트롤). Chromium 지원 여부 ❓ | 있으면 "조합 중이면 커밋 보류"로 정확해지지만 **없어도 위 규칙으로 충분**. 2단계 후반 |
| 키 횟수 | `keyDown` 전부 | 조합 중 키는 앱엔 `VK_PROCESSKEY`로 가지만 LL 훅·Raw Input 은 실제 VK 를 본다 ✅. 한/영·한자 키도 센다 | 횟수는 그대로. `VK_HANGUL`·`VK_HANJA`·`VK_PROCESSKEY`는 단축키 조합 판정에서 제외 |
| 값 변경 알림 | `kAXValueChanged` (안 오는 앱 대비 0.25초 뒤 재읽기) | `UIA_ValueValuePropertyId` 변경 이벤트(TSF 앱·Chromium 은 조합마다 옴 🔸). 안 오는 앱 대비 0.25초 재읽기는 그대로 | — |

### 1.5 대응이 없는 것 · 뒤집히는 것 (한눈에)

| 맥 | 윈도우 | 결론 |
|---|---|---|
| AppleScript 로 브라우저 주소 | 없음 | UIA 주소창(2단계 초반) → 확장 + Native Messaging(정확도 필요 시) |
| CodexBar 한도 파일 | 없음 | Codex 세션 `rate_limits` 폴백 + 직접 적은 리셋권만 |
| 보안 입력(`IsSecureEventInputEnabled`) 감지 | 개념 없음 | 불필요. `secure` 이벤트 종류는 윈도우에서 안 쓴다 |
| `AXManualAccessibility`(Electron) | 불필요 | Chromium 이 UIA 클라이언트를 감지해 스스로 켠다 |
| 비공개 CGS (Spaces 번호, 백그라운드 커서) | 커서: 불필요 / 번호: 공개 API 없음 | 따라가기만 구현, 방향은 포기 |
| `sharingType`(믿지 못함) | `WDA_EXCLUDEFROMCAPTURE`(믿을 만함) | 레이어드 창 호환 ❓ 확인 후 기본 켬 |
| `NSDataDetector` 날짜 | 없음 | 직접 파서, 두 OS 공유 |
| nspasteboard 숨김 타입 | 클립보드 포맷 3종 | 포맷 이름만 다름 |
| launchd KeepAlive | 작업 스케줄러 "실패 시 재시작" | 동등 |
| 손쉬운 사용·입력 모니터링 권한 | 없음 | 설치가 쉬움. 대신 **관리자 권한 창(UAC 올린 앱)의 입력·UI 는 못 본다** — 기록에 공백으로 남긴다 (`health`에 표시) |
| 메뉴바 아이콘 | 트레이 아이콘 | 동등 |
| Dock 윗변 = 바닥 | 작업 표시줄 위 = `rcWork` 아래변 | 동등 (작업 표시줄이 옆·위에 있을 수도 있다 → `rcWork` 그대로 쓰면 자동) |
| 전체 화면 앱 → 숨김 | `SHQueryUserNotificationState` + D3D 전체 화면은 어차피 topmost 를 덮는다 | 동등 이상 |

---

## 2. 스택 비교

평가 기준: 상시 CPU·메모리(사용자 기준: CPU 수 %, 메모리 100MB 안쪽) · 1인이 두 OS 행동 코드를 유지하는 비용 · 권한·설치 난이도.
참고 수치 ✅: 맥 Swift 앱은 CPU 절감 전 평균 3.6% (cpu-reduction.md), WindowPet(Swift) 44MB·CPU 0.25~1% (RESEARCH.md), BongoCat 웹뷰판 500MB+ (RESEARCH.md).

| 기준 | (a) C#/.NET 8 네이티브 | (b) Python + PySide6 | (c) Tauri / Rust |
|---|---|---|---|
| 오버레이 방식 | Win32 레이어드 창 + `UpdateLayeredWindow` 또는 Direct2D. **WPF 는 쓰지 않음** (WPF 창도 결국 레이어드 창이지만 프레임워크가 무겁고 NativeAOT 불가 ✅) | Qt 프레임리스 + `WA_TranslucentBackground`(내부적으로 레이어드 창). 클릭 통과는 `WindowTransparentForInput` 토글(네이티브 창 재생성) 또는 `nativeEvent`에서 `WM_NCHITTEST` 처리 | Tauri 본래 = WebView2 (RESEARCH.md 에서 거른 방식). "Rust 네이티브"(windows-rs + 레이어드 창)는 별개 선택지 |
| 상시 메모리 🔸 | Win32+D2D NativeAOT: 15~30MB. WPF 였다면 60~90MB | 80~130MB (Qt6 DLL + Python + Shiboken). **100MB 경계를 넘나든다** | WebView2: 120~200MB (프로세스 여럿). Rust 네이티브: 10~25MB |
| 상시 CPU 🔸 | 쉴 때 0%, 걸을 때 1~2% (30Hz 합성, 맥과 같은 설계) | 쉴 때 0~0.5%(타이머 정지 시), 걸을 때 2~4% (Python 틱 + Qt 페인트) | WebView2: 걸을 때 3~6%. Rust: (a)와 같음 |
| 입력 훅 안정성 | Raw Input 메시지 루프, 네이티브 콜백 → 시간 제한 문제 없음 | LL 훅 콜백이 Python 이면 GIL·GC 로 수백 ms 지연 가능 → 훅이 조용히 떨어짐 🔸. Raw Input 으로 피해야 함 | Rust: 문제 없음 |
| UIA | `IUIAutomation` COM (CsWin32 소스 생성으로 P/Invoke 자동) ✅. 관리형 `System.Windows.Automation`은 느려서 안 씀 🔸 | comtypes / pywinauto.uia — 됨. 호출당 Python 오버헤드 | windows-rs 에 UIA 포함 ✅ |
| 두 OS 유지 비용 | Swift 7,700 + C# 약 6,000 (행동 코드 두 벌). 순수 로직은 `shared/` 데이터·테스트 벡터로 동기 | 맥을 Python 으로 **교체**해야 한 벌이 된다. 교체하면: 맥 TCC 권한을 Python 인터프리터에 묶으려면 .app 번들 + 서명 필요(지금 build.sh 가 푸는 문제와 같음), pyobjc + Qt 로 메모리 2배, 지금 Swift 7,700줄 폐기. **교체 안 하면 (a)와 같은 두 벌** | 맥까지 Rust 로 가면 한 벌(BongoCat 이 간 길 ✅)이지만 Swift 7,700줄 재작성 + Rust 학습. 윈도우만 Rust 면 (a)와 같은 두 벌 |
| 권한·설치 | 권한 창 없음. NativeAOT 단일 exe 5~10MB, 런타임 설치 불필요 🔸. 서명 없으면 SmartScreen 경고(직접 빌드하면 무관) | Python 설치 또는 PyInstaller 60~150MB 폴더, Defender 오탐 가끔 🔸 | 단일 exe 5MB |
| 개발 속도 (1인, 에이전트 보조) | 높음: Swift 구조를 거의 그대로 옮긴다. CsWin32 가 Win32·COM 보일러플레이트를 줄임 | 가장 빠른 "첫 고양이". 메모리 목표를 150MB 로 늦추면 선택 가능 | Rust 는 가장 느림 (소유권·unsafe FFI). 메모리는 최고 |
| 위험 | NativeAOT 에서 COM interop 은 `ComWrappers`/CsWin32 생성 코드만 쓸 것 (리플렉션 기반 interop 불가) ✅ | 메모리·훅·패키징 세 가지가 모두 경계선 | 학습 비용이 실제 기능을 늦춤 |

**추천: (a) C#/.NET 8, Win32 + `UpdateLayeredWindow`(1단계) → 필요 시 Direct2D(1.5단계), NativeAOT.**
근거:
1. 맥 앱의 설계(프로세스 하나, 런루프, 투명 오버레이, 바뀐 프레임만 그리기, SQLite)를 그대로 옮길 수 있어 **설계 논의가 다시 필요 없다**. 윈도우 API 대응이 §1 표처럼 거의 1:1 이다.
2. 메모리·CPU 가 Swift 판과 같은 급이다 (🔸, 1일 스파이크로 확인: 고양이 한 장을 레이어드 창에 30Hz 로 띄우고 Working Set 측정).
3. 행동 코드 두 벌은 (b)(c) 모두 맥을 갈아엎지 않는 한 피할 수 없다. 그렇다면 윈도우 쪽은 가장 빨리·가볍게 되는 언어가 맞다.
4. 권한·설치가 윈도우에서 제일 단순한 조합이다 (exe 하나 + 작업 스케줄러 등록 스크립트).

(b)를 고를 조건: 메모리 한도를 150MB 로 늦추고, Python 으로 빨리 보고 싶을 때. 그 경우도 입력은 Raw Input, 오버레이는 QWidget 하나에 `QImage` 블릿, brain 과 같은 저장소 구조. (c) Rust 는 "맥도 언젠가 갈아엎겠다"가 전제일 때만.

---

## 3. 1단계 범위 (최소 가치) 와 단계별 규모

규모는 맥 코드 줄 수 기준 어림이고, C# 는 Win32·COM 선언 때문에 ±30% 🔸.

### 1단계 — 고양이만 (수집기·brain 없음)

| 기능 | 맥 근거 파일 (줄) | 윈도우에서 새로 필요한 것 | 어림 |
|---|---|---|---|
| 오버레이·그리기·스프라이트 | PetController 핵심 ~400 · +Draw 280 · PetSprites 329 · PixelArt 45 · PetThought 97 · PetHand 77 | 레이어드 창, DPI v2, WIC PNG, DirectWrite 글자, 프레임 버퍼 합성 | ~1,200 |
| 지형(창 윗변·벽) + 움직임 | PetTerrain 123 · +Motion 411 · PetSpaces 20 | EnumWindows+DWM, 가상 데스크톱 따라가기 | ~550 |
| 키 입력 반응 (타자 앞발) | InputTap 중 keyDown 부분 ~60 | Raw Input 키보드 등록 + `GetLastInputInfo` 유휴 | ~100 |
| AgentMonitor + 한도 규칙 | AgentMonitor 282 · QuotaRules 247 · QuotaWatch 중 폴백·수동 리셋권·메뉴 ~200 | 공유 모드 파일 열기, 작업 스케줄러 없이 6초 폴링 | ~700 |
| 알림 말풍선·생각 풍선 | +Notices 59 · 말풍선은 +Draw 에 포함 · `pet_cmd` 파일 명령 | — | ~100 |
| 메모·할 일 | +Menu 중 writeMemo ~40 · PetJournal ~60 · checkTodos | **한국어 날짜 파서 신규 ~100** | ~200 |
| 마우스(쓰다듬기·끌기)·기분 | +Mouse 175 · PetMood 43 | — | ~220 |
| 트레이·메뉴·설정·자동 실행 | main.swift 중 ~150 · LaunchAgent 62 · +Menu 나머지 ~120 | NotifyIcon, 작업 스케줄러 스크립트, settings.json | ~300 |
| **합계** | | | **약 3,300 (C# 3,000~4,500)** |

1단계에서 일부러 빼는 것: 밥·물·창문·햇살·나비·장난감·상자·노트북·커피·안경 (+Play 289, +Routine 198, PetLife 518, PetToys 331, PetProps 283 ≈ 1,600줄, 거의 순수 로직이라 **1.5단계**에 그대로 옮기면 된다). 단축키 코치(472)도 뺀다.

1단계 완료 기준: 데스크탑에서 고양이가 작업 표시줄 위와 창 윗변을 걷고, 타자 치면 앉아서 앞발을 두드리고, Claude/Codex 가 끝나면 말풍선을 띄우고, 우클릭 메뉴에서 메모를 남기며, 작업 관리자에서 CPU 평균 2% 아래·메모리 40MB 아래 🔸.

### 2단계 — 수집기

| 모듈 | 맥 (줄) | 윈도우 어림 | 메모 |
|---|---|---|---|
| AppWatcher + AX | 226 | ~350 | WinEventHook + UIA 캐시 요청 |
| TextCapture | 234 | ~300 | §1.4 IME 규칙 포함 |
| InputTap + ClickResolver | 190 | ~280 | Raw Input + ElementFromPoint |
| SystemWatcher | 162 | ~150 | 폴링이 알림으로 바뀌어 짧아짐 |
| Context (프라이버시) | 284 | ~250 | `shared/privacy_rules.json` 읽기 |
| Store + Log | 145 | ~150 | |
| BrowserWatcher | 162 | ~250 (UIA) / +확장 ~300 (JS) + ~150 (host) | 2단계 초반은 UIA |
| AIResponseCapture | 159 | ~180 | TextPattern |
| **합계** | **1,562** | **약 1,900~2,300** | brain 이 같은 스키마를 읽으므로 맥 brain 그대로 |

2.5단계: 단축키 코치 (472 → ~500, 규칙 표 OS별), Claude 한도(토큰 읽기 여부 결정 필요).

### 3단계 — brain · Clef

| 항목 | 규모 | 메모 |
|---|---|---|
| brain 경로 분기 + `clef_url: null` | ~40줄 | `actlog_brain.py` 수정, 두 OS 공용 |
| `brain/install.ps1` | ~40줄 | 작업 스케줄러 등록 |
| Clef (CUDA 데스크탑만) | 코드 0, 설치 문서 | llama.cpp CUDA 빌드 + Clef 모델 + `/v1/systemone`. 노트북은 Clef 없이 brain 만 (구간·타임라인) 또는 brain 도 생략 |

---

## 4. 공유할 것 과 저장소 구조

### 4.1 공유 목록

| 공유 대상 | 지금 위치 | 공유 방식 | 비고 |
|---|---|---|---|
| 고양이 그림 35장 (64/128px 한 줄 시트, 오른쪽 보기) | `assets/original-cat/current` | 그대로. 두 빌드 스크립트가 복사 | `SOURCE.txt` 의 제작 규칙(사진 실루엣, v12 달리기 기준)도 그대로 |
| 그림 해석 규칙: 칸 64, 128px 는 k=2, 발 기준선 49(원화)/48(팩), 이름 → 폴백 표, `Anims` 표(이름·칸·fps·loop·times), rim 색 4종, 보행(gait) 측정 | `PetSprites.swift` 상수들 | `shared/anims.json` + `docs/CAT_MOTION.md` | Anims 표만 JSON 으로 빼면 맥도 그 파일을 읽게 바꿀 수 있다 (선택) |
| 행동 규칙 (걷기 10fps·질주 한 바퀴 0.24초·점프 앞발 착지·벽 내려올 땐 꼬리부터·깜빡임 8~20초…) | `docs/CAT_MOTION.md`, `think()` 의 임계값(1.5초 타자·8초 딴짓·40초 산책·180초 잠) | 문서 + `shared/behavior.json`(임계값) | 두 구현이 같은 숫자를 읽는다 |
| brain | `brain/` | 그대로 (경로 분기만) | |
| SQLite `events` 스키마 (`schema_version 1`), `brain.db` 스키마 | `Store.swift`, `actlog_brain.py` | `shared/schema.sql` 한 벌로 빼고 둘 다 참조 | 이벤트 종류·payload 키 표는 `collector/README.md` 표를 `docs/EVENTS.md` 로 |
| 프라이버시 규칙: 차단 도메인, URL 민감 파라미터, 마스킹 정규식 9종 + Luhn, AI 사이트, 검색 엔진 규칙, 설정 기본값 | `Context.swift` | `shared/privacy_rules.json` + `shared/privacy_vectors.json`(Tests/logic 의 check 들을 JSON 으로) | 앱 차단 목록만 `{mac, win}` 쌍 |
| 한도 규칙 (단계·간격·피로 줄이기) | `QuotaRules.swift`, `docs/REMINDERS.md` | `shared/quota_vectors.json` (입력 창·리셋권 → 기대 알림) | 맥 테스트가 이미 순수 함수라 벡터 추출이 쉽다 |
| 날짜 파서 | `PetJournal.detectDate` + `QuotaWatch.parseExpiry` | `shared/date_parse_vectors.json` | 둘 다 직접 파서로 바꾼다 (맥은 NSDataDetector 폴백 유지) |
| 데이터 폴더 파일 규약: `config.json`, `brain.json`, `projects.json`, `memos.jsonl`, `feedback.jsonl`, `notices.jsonl`, `reset_passes.json`, `shortcuts.json`, `pet_cmd`(say:/urgent:/key:/재주 이름) | 맥 데이터 폴더 | `docs/DATA_DIR.md` | `pet_cmd` 는 다른 에이전트가 고양이에게 말 거는 통로라 두 OS 에서 같아야 한다 |
| 알림 문구·고양이 말투 | 코드 안 문자열 | `shared/lines.ko.json` (선택) | 두 벌 유지가 귀찮으면 뺀다 |

### 4.2 저장소 구조 제안

```
Meowgent/
  mac/          ← 지금 collector/ 를 통째로 옮김 (Package.swift, Sources, Tests, build.sh, Info.plist)
  win/          ← Meowgent.Win.csproj, src/, tests/, build.ps1, install.ps1
  brain/        ← actlog_brain.py, test_brain.py, install.sh, install.ps1
  shared/       ← schema.sql, privacy_rules.json, privacy_vectors.json, anims.json, behavior.json,
                   quota_vectors.json, date_parse_vectors.json
  assets/       ← original-cat/ (current, v1~v13), vendor/ (git 제외)
  docs/         ← RESEARCH.md, CAT_MOTION.md, REMINDERS.md, SHORTCUT_HINTS.md, WINDOWS_PORT.md, EVENTS.md, DATA_DIR.md
  DESIGN.md
```

- `collector/` → `mac/` 이동은 `build.sh` 의 `../assets` 상대 경로 깊이가 같아 그대로 돈다. 사이드 세션 노트의 `Sources.bak` 백업 경로만 바뀐다.
- 저장소가 아직 git 이 아니다. 이식을 시작하기 전에 git 으로 올려 두는 편이 두 OS 사이 동기화(데스크탑 ↔ 맥, 위키 동기화와 같은 경로)에 맞다.
- 윈도우 데이터 폴더는 `%LOCALAPPDATA%\ActLog` (brain 과 이름을 맞춘다). 설정은 레지스트리 대신 `settings.json` 으로 두어 맥 `UserDefaults` 키 이름(`petScale`, `petHomeX`, `petMeals`…)과 같은 키를 쓴다.

---

## 5. 시작 전에 확인할 것 (❓ 목록)

1. `WDA_EXCLUDEFROMCAPTURE` 가 `WS_EX_LAYERED` + `UpdateLayeredWindow` 창에서 캡처만 빼고 화면엔 그대로 보이는지 (안 되면 Direct2D+DirectComposition 경로로 1단계부터).
2. Raw Input(`RIDEV_INPUTSINK`) 이 관리자 권한 창에 입력 중일 때도 오는지. 안 오면 LL 훅과 같은 공백이고, `health` 에 적는다.
3. Chrome·Edge·Whale 주소창 UIA 값에 스킴(`https://`)이 들어오는지, 편집 중 판별이 되는지 (안 되면 확장으로).
4. Chromium `TextPattern.DocumentRange.GetText` 가 긴 AI 답변 페이지에서 몇 ms 인지 (2초 폴링에 맞는지).
5. MS 한글 IME 에서 조합 중 Enter 가 앱에도 전달되는지, `TextEditPattern.ConversionTarget` 을 Chromium 이 주는지.
6. NativeAOT 로 빌드한 C# 레이어드 창 스파이크의 Working Set·CPU (목표 40MB·걸을 때 2%).
7. Claude Code 윈도우판의 `~/.claude/projects` 폴더 이름 규칙 (드라이브 문자·역슬래시 치환).
