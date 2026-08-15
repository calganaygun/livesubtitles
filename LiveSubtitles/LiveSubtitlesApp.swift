import AppKit
import SwiftUI

@main
struct LiveSubtitlesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var subtitles = SubtitleCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(subtitles: subtitles)
        } label: {
            Image(systemName: subtitles.isRunning ? "captions.bubble.fill" : "captions.bubble")
        }

        Settings {
            SettingsView(subtitles: subtitles)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var subtitles: SubtitleCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(subtitles.isRunning ? "Stop Captions" : "Start Captions") {
            subtitles.toggle()
        }
        .keyboardShortcut("s")

        Button("Show Subtitle Window") {
            OverlayPanelController.shared.show()
        }

        Toggle("English Translation", isOn: Binding(
            get: { subtitles.translationEnabled },
            set: { subtitles.setTranslationEnabled($0) }
        ))

        Divider()

        Button("Settings…") {
            openSettings()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Live Subtitles") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        OverlayPanelController.shared.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SubtitleCoordinator.shared.stop()
    }
}

@MainActor
final class OverlayPanelController {
    static let shared = OverlayPanelController()

    private var panel: NSPanel?

    func install() {
        guard panel == nil else { return }

        let content = SubtitleOverlayView(subtitles: .shared)
        let hostingView = NSHostingView(rootView: content)
        let size = NSSize(width: 760, height: 190)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 72
        )

        let panel = SubtitlePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("SubtitleOverlay")
        panel.setContentSize(size)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func show() {
        install()
        panel?.orderFrontRegardless()
    }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
