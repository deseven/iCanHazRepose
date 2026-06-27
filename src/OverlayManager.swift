import AppKit
import SwiftUI
import Carbon

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
class OverlayManager {
    private var overlayWindows: [NSPanel] = []
    private var compactPanel: NSPanel?
    private var isCompactMode: Bool = false

    // Carbon global hotkey refs for escape (used by both full and compact overlays)
    private var escapeHotKeyRef: EventHotKeyRef?
    private var ctrlEscapeHotKeyRef: EventHotKeyRef?
    private var escapeEventHandlerRef: EventHandlerRef?

    // MARK: - Full overlay (all screens)

    func showBreakOverlay(timerManager: TimerManager) {
        dismissOverlay()

        for screen in NSScreen.screens {
            let isPrimary = screen == NSScreen.main
            let view = BreakOverlayView(timerManager: timerManager, isPrimary: isPrimary)

            let panel = KeyablePanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.contentView = NSHostingView(rootView: view)

            if isPrimary {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            overlayWindows.append(panel)
        }

        isCompactMode = false
        installKeyMonitor(timerManager: timerManager)
    }

    // MARK: - Compact overlay (single centered panel for fullscreen apps)

    func showCompactBreakOverlay(timerManager: TimerManager) {
        dismissOverlay()

        guard let screen = NSScreen.main else { return }

        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 420
        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.midY - panelHeight / 2
        let panelRect = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)

        let view = CompactBreakOverlayView(timerManager: timerManager)

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: view)

        panel.orderFrontRegardless()
        compactPanel = panel
        isCompactMode = true
        installKeyMonitor(timerManager: timerManager)
    }

    // MARK: - Dismiss

    func dismissWithAnimation(completion: @escaping () -> Void = {}) {
        let windows = isCompactMode ? (compactPanel.map { [$0] } ?? []) : overlayWindows
        for window in windows {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.dismissOverlay()
            completion()
        }
    }

    func dismissOverlay() {
        uninstallKeyMonitor()
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        compactPanel?.orderOut(nil)
        compactPanel = nil
        isCompactMode = false
    }

    // MARK: - Private

    private func installKeyMonitor(timerManager: TimerManager) {
        let allowSkip = UserDefaults.standard.bool(forKey: SettingsKey.allowSkipBreak)
        guard allowSkip else { return }

        registerEscapeHotkey { [weak timerManager] in
            DispatchQueue.main.async {
                timerManager?.skipBreak()
            }
        }
    }

    private func uninstallKeyMonitor() {
        unregisterEscapeHotkey()
    }

    // MARK: - Carbon global hotkey (escape, with/without control)

    private func registerEscapeHotkey(handler: @escaping () -> Void) {
        unregisterEscapeHotkey()

        let signature = fourCharCode("reps")

        // Hotkey 1: Escape (no modifiers)
        var hotKeyRef1: EventHotKeyRef?
        let status1 = RegisterEventHotKey(
            0x35, // kVK_Escape
            0,    // no modifiers
            EventHotKeyID(signature: signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef1
        )
        if status1 == noErr, let ref = hotKeyRef1 {
            escapeHotKeyRef = ref
        }

        // Hotkey 2: Ctrl+Escape
        var hotKeyRef2: EventHotKeyRef?
        let status2 = RegisterEventHotKey(
            0x35,               // kVK_Escape
            UInt32(controlKey), // ctrl modifier
            EventHotKeyID(signature: signature, id: 2),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef2
        )
        if status2 == noErr, let ref = hotKeyRef2 {
            ctrlEscapeHotKeyRef = ref
        }

        guard escapeHotKeyRef != nil || ctrlEscapeHotKeyRef != nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Use the handler directly via a heap-allocated context to avoid
        // Unmanaged pointer complexity with a closure capture.
        let ctx = EscapeHandlerContext(handler: handler)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, theEvent, userData) -> OSStatus in
                guard let theEvent = theEvent, let userData = userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hkCom = EventHotKeyID()
                guard GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil,
                    &hkCom
                ) == noErr, (hkCom.id == 1 || hkCom.id == 2) else { return OSStatus(eventNotHandledErr) }

                let ctx = Unmanaged<EscapeHandlerContext>.fromOpaque(userData).takeUnretainedValue()
                ctx.handler()
                return noErr
            },
            1,
            &eventType,
            ctxPtr,
            &escapeEventHandlerRef
        )

        if installStatus != noErr {
            Unmanaged<EscapeHandlerContext>.fromOpaque(ctxPtr).release()
            unregisterEscapeHotkey()
        }
    }

    private func unregisterEscapeHotkey() {
        if let ref = escapeHotKeyRef {
            UnregisterEventHotKey(ref)
            escapeHotKeyRef = nil
        }
        if let ref = ctrlEscapeHotKeyRef {
            UnregisterEventHotKey(ref)
            ctrlEscapeHotKeyRef = nil
        }
        if let handlerRef = escapeEventHandlerRef {
            RemoveEventHandler(handlerRef)
            escapeEventHandlerRef = nil
        }
    }
}

/// A simple heap-allocated object to hold the escape handler closure
/// for the Carbon event callback.
private class EscapeHandlerContext {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}

/// Convert a 4-character ASCII string to a FourCharCode (OSType).
private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf8 {
        result = (result << 8) | FourCharCode(char)
    }
    return result
}
