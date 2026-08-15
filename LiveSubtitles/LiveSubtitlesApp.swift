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
    private var standardFrame: NSRect?

    private let standardSize = NSSize(width: 760, height: 190)
    private let notchSize = NSSize(width: 560, height: 132)

    func install() {
        guard panel == nil else { return }

        let content = SubtitleOverlayView(subtitles: .shared)
        let hostingView = NSHostingView(rootView: content)
        let size = SubtitleCoordinator.shared.notchModeEnabled ? notchSize : standardSize
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
        panel.hasShadow = !SubtitleCoordinator.shared.notchModeEnabled
        panel.isMovableByWindowBackground = !SubtitleCoordinator.shared.notchModeEnabled
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        updatePlacement()
        panel.orderFrontRegardless()
    }

    func show() {
        install()
        panel?.orderFrontRegardless()
    }

    func updatePlacement() {
        guard let panel else { return }

        if SubtitleCoordinator.shared.notchModeEnabled {
            if panel.isMovableByWindowBackground {
                standardFrame = panel.frame
            }
            panel.setFrameAutosaveName("")
            panel.isMovableByWindowBackground = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            panel.setFrame(notchFrame(on: panel.screen ?? NSScreen.main), display: true, animate: true)
        } else {
            panel.isMovableByWindowBackground = true
            panel.hasShadow = true
            panel.ignoresMouseEvents = false
            panel.level = .floating
            panel.setContentSize(standardSize)
            _ = panel.setFrameAutosaveName("SubtitleOverlay")

            if let standardFrame {
                panel.setFrame(standardFrame, display: true, animate: true)
            }
        }
    }

    private func notchFrame(on screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screenFrame.midX - notchSize.width / 2,
            y: screenFrame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
