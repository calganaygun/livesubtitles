import Foundation
import Speech

@MainActor
final class SubtitleCoordinator: ObservableObject {
    static let shared = SubtitleCoordinator()

    @Published private(set) var transcript = "Press Start Captions in the menu bar"
    @Published var translation = ""
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var selectedLocaleIdentifier: String
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var fontSize: Double
    @Published private(set) var backgroundOpacity: Double

    let availableLocales: [LocaleOption]

    private let transcriber = SystemAudioTranscriber()

    private init() {
        let defaults = UserDefaults.standard
        let preferred = defaults.string(forKey: "sourceLocale") ?? Locale.current.identifier
        let locales = SFSpeechRecognizer.supportedLocales()
            .map { LocaleOption(identifier: $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        availableLocales = locales
        selectedLocaleIdentifier = locales.contains(where: { $0.identifier == preferred })
            ? preferred
            : (locales.first(where: { $0.identifier.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") })?.identifier ?? "en-US")
        translationEnabled = defaults.object(forKey: "translationEnabled") as? Bool ?? false
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 28
        backgroundOpacity = defaults.object(forKey: "backgroundOpacity") as? Double ?? 0.78
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        statusMessage = "Requesting permissions…"
        transcript = "Listening…"
        translation = ""

        Task {
            do {
                try await transcriber.start(localeIdentifier: selectedLocaleIdentifier) { [weak self] text in
                    Task { @MainActor in
                        self?.transcript = text
                        self?.statusMessage = nil
                    }
                }
                isRunning = true
                statusMessage = nil
            } catch {
                isRunning = false
                transcript = "Captions unavailable"
                translation = ""
                statusMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    func stop() {
        transcriber.stop()
        isRunning = false
        statusMessage = nil
        transcript = "Captions paused"
        translation = ""
    }

    func setLocale(_ identifier: String) {
        guard selectedLocaleIdentifier != identifier else { return }
        selectedLocaleIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "sourceLocale")
        if isRunning {
            stop()
            start()
        }
    }

    func setTranslationEnabled(_ enabled: Bool) {
        translationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "translationEnabled")
        if !enabled { translation = "" }
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        UserDefaults.standard.set(size, forKey: "fontSize")
    }

    func setBackgroundOpacity(_ opacity: Double) {
        backgroundOpacity = opacity
        UserDefaults.standard.set(opacity, forKey: "backgroundOpacity")
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let error = error as? LiveSubtitleError {
            return error.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }
}

struct LocaleOption: Identifiable, Hashable {
    let identifier: String
    var id: String { identifier }
    var name: String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
