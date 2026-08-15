import AppKit
import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @ObservedObject var subtitles: SubtitleCoordinator

    var body: some View {
        VStack(spacing: 8) {
            Text(subtitles.transcript)
                .font(.system(size: subtitles.fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity)

            if subtitles.translationEnabled, !subtitles.translation.isEmpty {
                Text(subtitles.translation)
                    .font(.system(size: max(16, subtitles.fontSize - 5), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }

            if let status = subtitles.statusMessage {
                HStack(spacing: 10) {
                    Label(status, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)

                    if status.contains("System Settings") {
                        Button("Open Settings") {
                            openScreenCaptureSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            TranslationBridge(subtitles: subtitles)
                .frame(width: 0, height: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(subtitles.backgroundOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .padding(4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live subtitles")
    }

    private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct TranslationBridge: View {
    @ObservedObject var subtitles: SubtitleCoordinator
    @State private var requests = TranslationRequestQueue()
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onAppear { refreshConfiguration() }
            .onChange(of: subtitles.translationEnabled) { _, _ in
                refreshConfiguration()
            }
            .onChange(of: subtitles.selectedLocaleIdentifier) { _, _ in
                refreshConfiguration()
            }
            .onChange(of: subtitles.transcript) { _, newText in
                guard subtitles.isRunning,
                      subtitles.translationEnabled,
                      !newText.isEmpty else { return }
                requests.submit(newText)
            }
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()

                    // Keep one TranslationSession alive. Recreating it for every
                    // partial transcript repeatedly presents the language-download sheet.
                    for await text in requests.stream {
                        guard !Task.isCancelled else { return }
                        let response = try await session.translate(text)
                        await MainActor.run {
                            guard text == subtitles.transcript else { return }
                            subtitles.translation = response.targetText
                        }
                    }
                } catch is CancellationError {
                    // Turning translation off cancels the long-lived session.
                } catch {
                    // Translation may be unavailable until the language pack is downloaded.
                }
            }
    }

    private func refreshConfiguration() {
        if subtitles.translationEnabled {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: subtitles.selectedLocaleIdentifier),
                target: Locale.Language(identifier: "en")
            )
        } else {
            configuration = nil
        }
    }

}

private final class TranslationRequestQueue {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var capturedContinuation: AsyncStream<String>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func submit(_ text: String) {
        continuation.yield(text)
    }

    deinit {
        continuation.finish()
    }
}

struct SettingsView: View {
    @ObservedObject var subtitles: SubtitleCoordinator

    var body: some View {
        Form {
            Section("Recognition") {
                Picker("Spoken language", selection: Binding(
                    get: { subtitles.selectedLocaleIdentifier },
                    set: { subtitles.setLocale($0) }
                )) {
                    ForEach(subtitles.availableLocales) { locale in
                        Text(locale.name).tag(locale.identifier)
                    }
                }
                .searchable(text: .constant(""))

                Toggle("Show English translation", isOn: Binding(
                    get: { subtitles.translationEnabled },
                    set: { subtitles.setTranslationEnabled($0) }
                ))
            }

            Section("Appearance") {
                LabeledContent("Text size") {
                    Slider(value: Binding(
                        get: { subtitles.fontSize },
                        set: { subtitles.setFontSize($0) }
                    ), in: 18...42, step: 1)
                    .frame(width: 220)
                }

                LabeledContent("Background") {
                    Slider(value: Binding(
                        get: { subtitles.backgroundOpacity },
                        set: { subtitles.setBackgroundOpacity($0) }
                    ), in: 0.35...0.95)
                    .frame(width: 220)
                }
            }

            Section {
                Text("Audio is captured from the Mac's system output. Speech recognition and translation use Apple's system frameworks. The first start asks for Screen & System Audio Recording and Speech Recognition access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 330)
        .padding()
    }
}
