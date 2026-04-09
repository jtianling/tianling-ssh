import SwiftUI
import SwiftTerm
import UIKit

struct SwiftTermBridgeView: UIViewRepresentable {
  let sshManager: SSHManager

  func makeUIView(context: Context) -> SwiftTerm.TerminalView {
    DispatchQueue.main.async {
      _ = sshManager.terminalView.becomeFirstResponder()
    }
    return sshManager.terminalView
  }

  func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
    if !uiView.isFirstResponder {
      DispatchQueue.main.async {
        _ = uiView.becomeFirstResponder()
      }
    }
  }
}
