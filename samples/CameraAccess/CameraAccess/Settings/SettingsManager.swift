import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case geminiAPIKey
    case openClawHost
    case openClawPort
    case openClawHookToken
    case openClawGatewayToken
    // Stored under a versioned name: tapping Save in Settings persists whatever
    // prompt was shown, which would otherwise pin an old default forever.
    case geminiSystemPrompt = "geminiSystemPromptV3"
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
    case closeUpPhotosEnabled
  }

  private init() {}

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { defaults.string(forKey: Key.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { defaults.set(newValue, forKey: Key.geminiAPIKey.rawValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? GeminiConfig.defaultSystemInstruction }
    set {
      // Only store a prompt the user actually changed. Saving the default as-is
      // would freeze it, and later app updates to the default would never arrive.
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let defaultTrimmed = GeminiConfig.defaultSystemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed == defaultTrimmed {
        defaults.removeObject(forKey: Key.geminiSystemPrompt.rawValue)
      } else {
        defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue)
      }
    }
  }

  // MARK: - OpenClaw

  var openClawHost: String {
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawHookToken: String {
    get { defaults.string(forKey: Key.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get { defaults.string(forKey: Key.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
    set { defaults.set(newValue, forKey: Key.openClawGatewayToken.rawValue) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { defaults.string(forKey: Key.webrtcSignalingURL.rawValue) ?? Secrets.webrtcSignalingURL }
    set { defaults.set(newValue, forKey: Key.webrtcSignalingURL.rawValue) }
  }

  // MARK: - Audio

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - Close-up photos

  /// When on, look_closely takes a real photo with the glasses: sharper, but the glasses
  /// click and flash their capture light every time (a Meta privacy rule apps cannot turn
  /// off). When off (the default), the assistant silently uses the latest live frame.
  var closeUpPhotosEnabled: Bool {
    get { defaults.object(forKey: Key.closeUpPhotosEnabled.rawValue) as? Bool ?? false }
    set { defaults.set(newValue, forKey: Key.closeUpPhotosEnabled.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled, .closeUpPhotosEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
