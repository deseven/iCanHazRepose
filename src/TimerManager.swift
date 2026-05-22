import Foundation
import Combine
import AppKit
import CoreGraphics
import IOKit.pwr_mgt

enum TimerState {
    case working
    case onBreak
    case paused
}

enum PauseReason {
    case manual
    case meeting
    case idle
    case breakPending  // Work timer expired during meeting, waiting for meeting to end
}

enum SettingsKey {
    static let workDurationMinutes = "workDurationMinutes"
    static let breakDurationSeconds = "breakDurationSeconds"
    static let pauseDuringMeetings = "pauseDuringMeetings"
    static let allowSkipBreak = "allowSkipBreak"
    static let muteSounds = "muteSounds"
    static let pauseWhenIdle = "pauseWhenIdle"
    static let skippedUpdate = "skippedUpdate"
    static let hideMenuBarTimer = "hideMenuBarTimer"
}

@MainActor
class TimerManager: ObservableObject {
    @Published var state: TimerState = .working
    @Published var remainingSeconds: Int = 0

    private var timerCancellable: AnyCancellable?
    private var tickCount: Int = 0
    private var secondsBeforePause: Int = 0
    private var pauseReason: PauseReason = .manual
    private var breakStartTime: Date = .distantPast
    private var graceAnimTask: Task<Void, Never>?
    private var wasInMeeting: Bool = false
    private var wasIdle: Bool = false

    let meetingDetector = MeetingDetector()
    let overlayManager = OverlayManager()
    private let postMeetingBreakDelay = 5
    let breakGracePeriod: TimeInterval = 1.5

    @Published var isInGracePeriod: Bool = false
    @Published var graceProgress: Double = 1

    // Activity to prevent App Nap
    private var activity: NSObjectProtocol?

    var workDurationSeconds: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.workDurationMinutes).clamped(to: 1...120) * 60
    }

    var breakDurationSeconds: Int {
        let val = UserDefaults.standard.integer(forKey: SettingsKey.breakDurationSeconds)
        // FIXME: clamp to 9:59 due to UI issues
        return val.clamped(to: 5...599)
    }

    var pauseDuringMeetings: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.pauseDuringMeetings)
    }

    var muteSounds: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.muteSounds)
    }

    var pauseWhenIdle: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.pauseWhenIdle)
    }

    var menuBarText: String {
        switch state {
        case .working:
            return formatTime(remainingSeconds)
        case .onBreak:
            return "Break \(formatTime(remainingSeconds))"
        case .paused:
            switch pauseReason {
            case .meeting:
                return "Meeting \(formatTime(secondsBeforePause))"
            case .breakPending:
                return "Meeting"
            case .idle:
                return "Idle"
            case .manual:
                return "Paused \(formatTime(secondsBeforePause))"
            }
        }
    }

    var pauseStatusText: String? {
        guard state == .paused else { return nil }
        switch pauseReason {
        case .meeting:
            return meetingDetector.meetingSource.map { "Paused — \($0)" } ?? "Paused — Meeting"
        case .breakPending:
            return meetingDetector.meetingSource.map { "\($0) — Break pending" } ?? "In meeting — Break pending"
        case .idle:
            return "Paused — Idle"
        case .manual:
            return "Paused"
        }
    }

    var currentPauseReason: PauseReason? {
        state == .paused ? pauseReason : nil
    }

    var isInMeeting: Bool {                                                                                                                             
        meetingDetector.isInMeeting                                                                                                                     
    } 

    init() {
        // Register defaults
        UserDefaults.standard.register(defaults: [
            SettingsKey.workDurationMinutes: 20,
            SettingsKey.breakDurationSeconds: 20,
            SettingsKey.pauseDuringMeetings: true,
            SettingsKey.allowSkipBreak: true,
            SettingsKey.muteSounds: false,
            SettingsKey.pauseWhenIdle: true,
            SettingsKey.hideMenuBarTimer: false,
        ])
        // Start timer and ticker (ticker runs for app lifetime)
        remainingSeconds = workDurationSeconds
        state = .working
        startTicking()

        // Reset work timer on wake — sleep time isn't work time
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
    }

    private func handleWake() {
        switch state {
        case .working:
            Log.info("Timer restarted after system wake")
            remainingSeconds = workDurationSeconds
        case .onBreak:
            Log.info("Break dismissed after system wake, timer restarted")
            overlayManager.dismissOverlay()
            remainingSeconds = workDurationSeconds
            state = .working
        case .paused:
            break
        }
    }

    func start() {
        Log.info("Timer started: work=\(workDurationSeconds / 60)min, break=\(breakDurationSeconds)s")
        remainingSeconds = workDurationSeconds
        state = .working
    }

    func pause() {
        guard state == .working else { return }
        Log.info("Timer paused by user")
        secondsBeforePause = remainingSeconds
        state = .paused
        pauseReason = .manual
    }

    func resume() {
        guard state == .paused else { return }
        Log.info("Timer resumed by user")
        remainingSeconds = secondsBeforePause
        state = .working
        pauseReason = .manual
    }

    func skipBreak() {
        Log.info("Break overlay closed: user cancelled")
        graceAnimTask?.cancel()
        graceAnimTask = nil
        overlayManager.dismissOverlay()
        remainingSeconds = workDurationSeconds
        state = .working
    }

    func togglePause() {
        if state == .working {
            pause()
        } else if state == .paused && pauseReason != .meeting && pauseReason != .breakPending {
            resume()
        }
    }

    // MARK: - Private

    private func startTicking() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Break timer running"
        )

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        tickCount += 1

        // Check for meetings and idle every 5 seconds
        if tickCount % 5 == 0 {
            if pauseDuringMeetings { checkMeetingStatus() }
            if pauseWhenIdle { checkIdleStatus() }
        }

        switch state {
        case .paused:
            break

        case .working:
            remainingSeconds -= 1
            if remainingSeconds <= 0 {
                startBreak()
            }

        case .onBreak:
            let elapsed = Date().timeIntervalSince(breakStartTime)
            if elapsed >= breakGracePeriod {
                if isInGracePeriod {
                    isInGracePeriod = false
                    graceAnimTask?.cancel()
                    graceAnimTask = nil
                }
                graceProgress = 1
                remainingSeconds -= 1
                if remainingSeconds <= 0 {
                    endBreak()
                }
            }
        }
    }

    // MARK: - Fullscreen Detection

    func isFrontmostAppFullscreen() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in windowList {
            let layer = window[kCGWindowLayer as String] as? Int64 ?? -1
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            guard layer == 0, alpha > 0.5 else { continue }

            let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0

            for screen in NSScreen.screens {
                let sf = screen.frame
                if abs(w - sf.width) < 2 && abs(h - sf.height) < 2 &&
                   abs(x - sf.minX) < 2 && abs(y - sf.minY) < 2 {
                    return true
                }
            }
        }
        return false
    }

    private func startBreak() {
        // Check for meeting immediately before showing break overlay
        if pauseDuringMeetings {
            meetingDetector.check()
            if meetingDetector.isInMeeting {
                Log.info("Break overlay suppressed: meeting in progress")
                secondsBeforePause = 0
                state = .paused
                pauseReason = .breakPending
                return
            }
        }

        remainingSeconds = breakDurationSeconds
        state = .onBreak
        breakStartTime = Date()
        isInGracePeriod = true
        graceProgress = 0
        startGraceAnimation()

        if isFrontmostAppFullscreen() {
            overlayManager.showCompactBreakOverlay(timerManager: self)
            Log.info("Break overlay triggered: compact overlay (fullscreen app detected)")
        } else {
            overlayManager.showBreakOverlay(timerManager: self)
            Log.info("Break overlay triggered: full overlay (work timer expired)")
        }

        if !muteSounds { NSSound(named: "Glass")?.play() }
    }

    private func endBreak() {
        Log.info("Break overlay closed: timeout completed")
        graceAnimTask?.cancel()
        graceAnimTask = nil
        if !muteSounds { NSSound(named: "Blow")?.play() }
        overlayManager.dismissWithAnimation { [weak self] in
            guard let self else { return }
            self.remainingSeconds = self.workDurationSeconds
            self.state = .working
        }
    }

    private func startGraceAnimation() {
        graceAnimTask?.cancel()
        graceAnimTask = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= self.breakGracePeriod { break }
                let progress = min(1.0, elapsed / self.breakGracePeriod)
                await MainActor.run { [weak self] in
                    self?.graceProgress = progress
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
            if !Task.isCancelled {
                await MainActor.run { [weak self] in
                    self?.graceProgress = 1
                }
            }
        }
    }

    private func checkMeetingStatus() {
        meetingDetector.check()

        if meetingDetector.isInMeeting {
            if !wasInMeeting {
                Log.info("Meeting mode entered (\(meetingDetector.meetingSource ?? "unknown"))")
                wasInMeeting = true
            }
            // Timer keeps running during meetings when working — no pause
            if state == .onBreak {
                // If a meeting starts during a break, skip the break
                skipBreak()
                secondsBeforePause = remainingSeconds
                state = .paused
                pauseReason = .meeting
            }
        } else {
            if wasInMeeting {
                Log.info("Meeting mode left")
                wasInMeeting = false
            }
            if state == .paused && pauseReason == .breakPending {
                // Meeting ended with break pending — short countdown then break
                remainingSeconds = postMeetingBreakDelay
                state = .working
            } else if state == .paused && pauseReason == .meeting {
                // Meeting ended (break was skipped), resume
                resume()
            }
        }
    }

    // MARK: - Idle Detection

    #if DEBUG
    private let idleThreshold: TimeInterval = 30 // 30 seconds for testing
    #else
    private let idleThreshold: TimeInterval = 300 // 5 minutes
    #endif

    private func checkIdleStatus() {
        // kCGAnyInputEventType (~0) checks all input event types
        let idleTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)

        if idleTime >= idleThreshold && !hasActiveDisplaySleepAssertion() {
            if state == .working {
                if !wasIdle {
                    Log.info("Idle mode entered (idle for \(Int(idleTime))s)")
                    wasIdle = true
                }
                secondsBeforePause = remainingSeconds
                state = .paused
                pauseReason = .idle
            }
        } else {
            if wasIdle {
                Log.info("Idle mode left")
                wasIdle = false
            }
            if state == .paused && pauseReason == .idle {
                resumeFromIdle()
            }
        }
    }

    private func resumeFromIdle() {
        guard state == .paused && pauseReason == .idle else { return }

        // Check for active meeting before resuming to avoid a gap
        if pauseDuringMeetings {
            meetingDetector.check()
            if meetingDetector.isInMeeting {
                secondsBeforePause = workDurationSeconds
                pauseReason = .meeting
                return
            }
        }

        remainingSeconds = workDurationSeconds
        state = .working
    }

    private func hasActiveDisplaySleepAssertion() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let dict = assertions?.takeRetainedValue() as? [String: [[String: Any]]] else {
            return false
        }

        for (_, processAssertions) in dict {
            for assertion in processAssertions {
                if let type = assertion["AssertType"] as? String,
                   type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleep" {
                    return true
                }
            }
        }
        return false
    }

}

func formatTime(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
