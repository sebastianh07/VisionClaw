import Foundation

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private let maxHistoryTurns = 10

  private static let stableSessionKey = "agent:main:glass"

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.stableSessionKey
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GeminiConfig.openClawBaseURL)/v1/chat/completions") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, response) = try await pingSession.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch code {
      case 200...299:
        connectionState = .connected
      case 401, 403:
        connectionState = .unreachable("wrong token")
      case 404:
        connectionState = .unreachable("wrong port")
      default:
        connectionState = .unreachable("HTTP \(code)")
      }
      NSLog("[OpenClaw] Gateway check: HTTP %d", code)
    } catch {
      let reason = Self.shortReason(for: error)
      connectionState = .unreachable(reason)
      NSLog("[OpenClaw] Gateway unreachable: %@ (%@)", reason, error.localizedDescription)
    }
  }

  // MARK: - Chess board from the camera

  /// Sends a camera picture to the computer's /vision/chess endpoint. The computer reads the
  /// board, checks it is a legal position, and runs Stockfish. Its answer is returned as text
  /// for the voice model to say; a board it could not read comes back as an explanation.
  func analyzeChessBoard(jpeg: Data, sideToMove: String?) async -> ToolResult {
    let toolName = "chess_board"
    lastToolCallStatus = .executing(toolName)
    guard let url = URL(string: "\(GeminiConfig.openClawBaseURL)/vision/chess") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("The computer's address in Settings is not valid.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["image_base64": jpeg.base64EncodedString(), "mime_type": "image/jpeg"]
    if let side = sideToMove?.lowercased(), side == "white" || side == "black" {
      body["side_to_move"] = side
    }
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200...299).contains(code) else {
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure(code == 401
          ? "The computer rejected the token saved in Settings."
          : "The computer could not read the board (HTTP \(code)).")
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let answer = json["answer"] as? String else {
        lastToolCallStatus = .failed(toolName, "Bad reply")
        return .failure("The computer's reply could not be read.")
      }
      lastToolCallStatus = .completed(toolName)
      return .success(answer)
    } catch {
      let reason = Self.shortReason(for: error)
      lastToolCallStatus = .failed(toolName, reason)
      return .failure("I could not reach the computer (\(reason)).")
    }
  }

  /// A few words a person can act on, shown in the status pill.
  static func shortReason(for error: Error) -> String {
    guard let urlError = error as? URLError else { return "error" }
    switch urlError.code {
    case .appTransportSecurityRequiresSecureConnection: return "blocked by iOS"
    case .unsupportedURL, .badURL: return "check Host"
    case .timedOut: return "timed out"
    case .cannotConnectToHost: return "PC not answering"
    case .cannotFindHost, .dnsLookupFailed: return "name not found"
    case .notConnectedToInternet: return "no internet"
    case .networkConnectionLost: return "connection lost"
    case .secureConnectionFailed, .serverCertificateUntrusted: return "https problem"
    default: return "error \(urlError.code.rawValue)"
    }
  }

  func resetSession() {
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.openClawBaseURL)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    // Append the new user message to conversation history
    conversationHistory.append(["role": "user", "content": task])

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation", conversationHistory.count)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        // Append assistant response to history for continuity
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }
}
