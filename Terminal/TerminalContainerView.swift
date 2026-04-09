import SwiftUI

struct TerminalContainerView: View {
  @Bindable var sshManager: SSHManager
  var onDisconnect: (() -> Void)?

  var body: some View {
    ZStack {
      SwiftTermBridgeView(sshManager: sshManager)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      switch sshManager.connectionState {
      case .connecting:
        connectingOverlay

      case .failed(let message):
        failedOverlay(message: message)

      default:
        EmptyView()

      }
    }
  }

  private var connectingOverlay: some View {
    VStack(spacing: 12) {
      ProgressView()
        .tint(.white)
      Text("Connecting...")
        .foregroundStyle(.white)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black.opacity(0.7))
  }

  private func failedOverlay(message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.yellow)

      Text("Connection Failed")
        .font(.headline)
        .foregroundStyle(.white)

      Text(message)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)

      Button {
        sshManager.disconnect()
        onDisconnect?()
      } label: {
        Text("Disconnect")
          .padding(.horizontal, 24)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black.opacity(0.85))
  }
}
