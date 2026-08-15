import AppKit
import SwiftUI
import Translation

struct SubtitleOverlayView: View {
    @ObservedObject var subtitles: SubtitleCoordinator

    var body: some View {
        VStack(spacing: subtitles.notchModeEnabled ? 5 : 8) {
            if subtitles.notchModeEnabled {
                NotchCaptionLine(
                    text: subtitles.transcript,
                    font: .system(size: displayedFontSize, weight: .semibold, design: .rounded),
                    color: .white,
                    height: displayedFontSize + 8
                )
            } else {
                Text(subtitles.transcript)
                    .font(.system(size: displayedFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
            }

            if subtitles.translationEnabled, !subtitles.translation.isEmpty {
                if subtitles.notchModeEnabled {
                    NotchCaptionLine(
                        text: subtitles.translation,
                        font: .system(size: max(14, displayedFontSize - 5), weight: .medium, design: .rounded),
                        color: .white.opacity(0.82),
                        height: max(14, displayedFontSize - 5) + 7
                    )
                } else {
                    Text(subtitles.translation)
                        .font(.system(size: max(16, subtitles.fontSize - 5), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
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
        .padding(.horizontal, subtitles.notchModeEnabled ? 22 : 26)
        .padding(.top, subtitles.notchModeEnabled ? 38 : 18)
        .padding(.bottom, subtitles.notchModeEnabled ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if subtitles.notchModeEnabled {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 24,
                    bottomTrailingRadius: 24,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(.black)
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 24,
                        bottomTrailingRadius: 24,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .stroke(.white.opacity(0.1), lineWidth: 1)
                }
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black.opacity(subtitles.backgroundOpacity))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
        .padding(subtitles.notchModeEnabled ? 0 : 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live subtitles")
    }

    private var displayedFontSize: Double {
        subtitles.notchModeEnabled ? min(subtitles.fontSize, 24) : subtitles.fontSize
    }

    private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct NotchCaptionLine: View {
    let text: String
    let font: Font
    let color: Color
    let height: Double

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        Text(text)
                            .font(font)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("caption-end")
                    }
                    .frame(minWidth: geometry.size.width, alignment: .center)
                }
                .scrollIndicators(.hidden)
                .allowsHitTesting(false)
                .onAppear {
                    scrollToEnd(using: scrollProxy, animated: false)
                }
                .onChange(of: text) { _, _ in
                    scrollToEnd(using: scrollProxy, animated: true)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(text)
    }

    private func scrollToEnd(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.linear(duration: 0.16)) {
                    proxy.scrollTo("caption-end", anchor: .trailing)
                }
            } else {
                proxy.scrollTo("caption-end", anchor: .trailing)
            }
        }
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
                Toggle("Show captions at the MacBook notch", isOn: Binding(
                    get: { subtitles.notchModeEnabled },
                    set: { subtitles.setNotchModeEnabled($0) }
                ))

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
