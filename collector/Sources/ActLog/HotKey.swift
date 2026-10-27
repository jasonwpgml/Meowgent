import AppKit
import Carbon

/// 전역 단축키 하나 (Carbon RegisterEventHotKey). 손쉬운 사용·입력 모니터링 권한 없이 동작하고,
/// 누름·뗌을 따로 알려 줘서 "누르고 있는 동안 말하기"를 만들 수 있다.
/// ⌃⌥Space 는 macOS 기본 "다음 입력 소스 선택"과 겹쳐 쓰지 않는다. ⌥ 나 ⇧ 만 쓴 조합은 macOS 15 부터 막힌다.
final class HotKey {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var byID: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    /// keyCode: kVK_* , modifiers: cmdKey | optionKey | controlKey | shiftKey
    init?(keyCode: Int, modifiers: Int) {
        HotKey.installHandler()
        let id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x4D454F57), id: id)   // 'MEOW'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.write("전역 단축키 등록 실패 (\(status)) — 다른 앱이 쓰고 있을 수 있다")
            return nil
        }
        HotKey.byID[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard let key = HotKey.byID[hk.id] else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { key.onDown?() } else { key.onUp?() }
            return noErr
        }, types.count, &types, nil, nil)
    }
}
