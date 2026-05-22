import AppKit
import SwiftUI

struct CompactBreakOverlayView: View {
    @ObservedObject var timerManager: TimerManager
    @AppStorage(SettingsKey.allowSkipBreak) private var allowSkipBreak: Bool = true
    @State private var breathe = false
    @State private var appeared = false
    @State private var ringProgress: CGFloat = 0

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack {
            // Blurred dark background
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.3))

            VStack(spacing: 28) {
                // Progress ring with breathing animation
                ZStack {
                    // Outer breathing ring
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 2)
                        .frame(width: 140, height: 140)
                        .scaleEffect(breathe ? 1.1 : 0.9)

                    // Progress ring
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.4, green: 0.5, blue: 1.0).opacity(0.8),
                                    Color(red: 0.6, green: 0.4, blue: 1.0).opacity(0.6),
                                    Color(red: 0.4, green: 0.5, blue: 1.0).opacity(0.3),
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 115, height: 115)
                        .rotationEffect(.degrees(-90))

                    // Inner circle
                    Circle()
                        .fill(.white.opacity(0.05))
                        .frame(width: 100, height: 100)
                        .scaleEffect(breathe ? 1.04 : 0.97)

                    // Timer inside the ring
                    Text(formatTime(timerManager.remainingSeconds))
                        .font(.system(size: 30, weight: .light, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .contentTransition(.numericText())
                }

                VStack(spacing: 8) {
                    Text("Time to Rest")
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .opacity(appeared ? 1 : 0)

                    Text("Look away from the screen, stretch, and re-pose")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .opacity(appeared ? 1 : 0)
                }

                // Escape hint (non-clickable — mouse passes through to fullscreen app)
                if allowSkipBreak {
                    HStack(spacing: 8) {
                        Text("Skip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("esc")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
                    .opacity(appeared ? 1 : 0)
                }
            }
            .padding(40)
        }
        .frame(width: 360, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .onAppear {
            if reduceMotion {
                breathe = true
            } else {
                withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            withAnimation(.easeOut(duration: 0.6)) {
                appeared = true
            }
            updateRingProgress()
        }
        .onChangeCompat(of: timerManager.remainingSeconds) {
            updateRingProgress()
        }
    }

    private func updateRingProgress() {
        let total = CGFloat(timerManager.breakDurationSeconds)
        let remaining = CGFloat(timerManager.remainingSeconds)
        let progress = total > 0 ? (total - remaining) / total : 0
        if reduceMotion {
            ringProgress = progress
        } else {
            withAnimation(.linear(duration: 1)) {
                ringProgress = progress
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, _ in action() }
        } else {
            self.onChange(of: value) { _ in action() }
        }
    }
}

// NSViewRepresentable for visual effect blur
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 24
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
