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
    private var keyMonitor: Any?
    private var isCompactMode: Bool = false

    // Carbon global hotkey refs for compact mode escape
    private var escapeHotKeyRef: EventHotKeyRef?
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

    func dismissWithAnimation() {
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

        if isCompactMode {
            registerEscapeHotkey { [weak timerManager] in
                DispatchQueue.main.async {
                    timerManager?.skipBreak()
                }
            }
        } else {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    timerManager.skipBreak()
                    return nil
                }
                return event
            }
        }
    }

    private func uninstallKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        unregisterEscapeHotkey()
    }

    // MARK: - Carbon global hotkey (escape, no modifiers)

    private func registerEscapeHotkey(handler: @escaping () -> Void) {
        unregisterEscapeHotkey()

        let hotKeyID = EventHotKeyID(signature: fourCharCode("reps"), id: 1)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            0x35, // kVK_Escape
            0,    // no modifiers
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let ref = hotKeyRef else { return }
        escapeHotKeyRef = ref

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
                ) == noErr, hkCom.id == 1 else { return OSStatus(eventNotHandledErr) }

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
