import Foundation
import UIKit

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3

  /// Supplied by the session wiring as closures, so the router stays independent of
  /// the camera stack. When they are missing, look_closely reports that plainly.
  var captureStill: (() async -> UIImage?)?
  var sendStill: ((UIImage) -> Void)?

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    // look_closely is answered on the phone: capture a sharp still and push it into
    // the model's view. It never goes to OpenClaw, so it is handled before the breaker.
    if callName == "look_closely" {
      let task = Task { @MainActor in
        guard let captureStill = self.captureStill, let sendStill = self.sendStill else {
          sendResponse(self.buildToolResponse(
            callId: callId, name: callName,
            result: .failure("No camera is streaming, so there is nothing to photograph.")))
          self.inFlightTasks.removeValue(forKey: callId)
          return
        }
        let image = await captureStill()
        guard !Task.isCancelled else { return }

        let result: ToolResult
        if let image {
          sendStill(image)
          result = .success(
            "A fresh, higher-quality image of what the user sees was just sent to your view. Answer from "
              + "that image. If you still cannot read it, ask the user to move closer or hold still.")
        } else {
          result = .failure("The photo could not be captured. Ask the user to hold still and try again.")
        }
        NSLog("[ToolCall] look_closely -> %@", image == nil ? "failed" : "sent still")
        sendResponse(self.buildToolResponse(callId: callId, name: callName, result: result))
        self.inFlightTasks.removeValue(forKey: callId)
      }
      inFlightTasks[callId] = task
      return
    }

    // chess_board: take a picture of what the user sees and let the computer read the
    // board and run Stockfish. The voice model never reads the board itself.
    if callName == "chess_board" {
      let side = call.args["side_to_move"] as? String
      let task = Task { @MainActor in
        defer { self.inFlightTasks.removeValue(forKey: callId) }
        guard let captureStill = self.captureStill else {
          sendResponse(self.buildToolResponse(
            callId: callId, name: callName,
            result: .failure("No camera is streaming, so I cannot see the board.")))
          return
        }
        let image = await captureStill()
        guard !Task.isCancelled else { return }
        guard let image,
              let jpeg = image.downscaled(maxDimension: GeminiConfig.stillMaxDimension)
                .jpegData(compressionQuality: GeminiConfig.stillJPEGQuality) else {
          sendResponse(self.buildToolResponse(
            callId: callId, name: callName,
            result: .failure("I could not get a picture of the board. Ask the user to look at it and try again.")))
          return
        }
        let result = await self.bridge.analyzeChessBoard(jpeg: jpeg, sideToMove: side)
        guard !Task.isCancelled else { return }
        NSLog("[ToolCall] chess_board -> %@", String(describing: result))
        sendResponse(self.buildToolResponse(callId: callId, name: callName, result: result))
      }
      inFlightTasks[callId] = task
      return
    }

    // Circuit breaker: stop sending tool calls after repeated failures
    if consecutiveFailures >= maxConsecutiveFailures {
      NSLog("[ToolCall] Circuit breaker open (%d consecutive failures), rejecting %@",
            consecutiveFailures, callId)
      let errorResult: ToolResult = .failure(
        "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. " +
        "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
      )
      let response = buildToolResponse(callId: callId, name: callName, result: errorResult)
      sendResponse(response)
      return
    }

    let task = Task { @MainActor in
      let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
      let result = await bridge.delegateTask(task: taskDesc, toolName: callName)

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      switch result {
      case .success:
        self.consecutiveFailures = 0
      case .failure:
        self.consecutiveFailures += 1
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
    consecutiveFailures = 0
  }

  // MARK: - Private

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
