import Foundation

// MARK: - Gemini Tool Call (parsed from server JSON)

struct GeminiFunctionCall {
  let id: String
  let name: String
  let args: [String: Any]
}

struct GeminiToolCall {
  let functionCalls: [GeminiFunctionCall]

  init?(json: [String: Any]) {
    guard let toolCall = json["toolCall"] as? [String: Any],
          let calls = toolCall["functionCalls"] as? [[String: Any]] else {
      return nil
    }
    self.functionCalls = calls.compactMap { call in
      guard let id = call["id"] as? String,
            let name = call["name"] as? String else { return nil }
      let args = call["args"] as? [String: Any] ?? [:]
      return GeminiFunctionCall(id: id, name: name, args: args)
    }
  }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
  let ids: [String]

  init?(json: [String: Any]) {
    guard let cancellation = json["toolCallCancellation"] as? [String: Any],
          let ids = cancellation["ids"] as? [String] else {
      return nil
    }
    self.ids = ids
  }
}

// MARK: - Tool Result

enum ToolResult {
  case success(String)
  case failure(String)

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": result]
    case .failure(let error):
      return ["error": error]
    }
  }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
  case idle
  case executing(String)
  case completed(String)
  case failed(String, String)
  case cancelled(String)

  var displayText: String {
    switch self {
    case .idle: return ""
    case .executing(let name): return "Running: \(name)..."
    case .completed(let name): return "Done: \(name)"
    case .failed(let name, let err): return "Failed: \(name) - \(err)"
    case .cancelled(let name): return "Cancelled: \(name)"
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - Tool Declarations (for Gemini setup message)

enum ToolDeclarations {

  static func allDeclarations() -> [[String: Any]] {
    return [execute, lookClosely, chessBoard]
  }

  /// Sends a picture of what the user sees to the computer, which reads the board with a
  /// vision model chosen for accuracy, checks the position is legal, and asks Stockfish.
  static let chessBoard: [String: Any] = [
    "name": "chess_board",
    "description": "Read the chess board the user is looking at (a real board or one on a screen) and get "
      + "the best move from the Stockfish chess engine on the user's computer. Use this for any question "
      + "about a chess position the user can see. Never read the board or choose a move yourself. It takes "
      + "about ten seconds, so first say a short acknowledgement such as \"Let me look at the board.\"",
    "parameters": [
      "type": "object",
      "properties": [
        "side_to_move": [
          "type": "string",
          "enum": ["white", "black"],
          "description": "Whose turn it is, if the user said so or it is clear. Leave it out if unknown; "
            + "the side at the bottom of the view is then assumed."
        ]
      ],
      "required": [] as [String]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  /// The live view is one small compressed frame per second: enough to know a page is
  /// being held up, not enough to read it. This asks for one sharp still instead. The
  /// image arrives as a new frame, not as this tool's result, because Live function
  /// responses carry text only.
  static let lookClosely: [String: Any] = [
    "name": "look_closely",
    "description": "Capture a sharp, high-resolution photo of what the user is looking at right now. "
      + "Use this whenever the answer depends on fine visual detail the live view is too coarse for: "
      + "reading a question, text, a screen, a label, a receipt, handwriting, small print or code, "
      + "or telling similar objects apart. After it returns, a high-resolution image arrives in your "
      + "view. Answer from that image, not from the earlier blurry frames.",
    "parameters": [
      "type": "object",
      "properties": [
        "looking_for": [
          "type": "string",
          "description": "What you are trying to read or identify, for example 'the question and its answer choices'."
        ]
      ],
      "required": [] as [String]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
}
