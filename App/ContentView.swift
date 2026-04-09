import SwiftUI

struct ContentView: View {
  @State private var sessionManager = SessionManager()
  @State private var showingTerminal = false

  var body: some View {
    NavigationStack {
      SessionListView(sessionManager: sessionManager)
    }
    .fullScreenCover(isPresented: terminalBinding) {
      ActiveTerminalView(
        sessionManager: sessionManager,
        onDismiss: {
          showingTerminal = false
          sessionManager.activeSessionID = nil
        }
      )
    }
    .onChange(of: sessionManager.activeSessionID) { _, newValue in
      if newValue != nil {
        showingTerminal = true
      }
    }
  }

  private var terminalBinding: Binding<Bool> {
    Binding(
      get: {
        showingTerminal && sessionManager.activeSession != nil
      },
      set: { newValue in
        showingTerminal = newValue
      }
    )
  }
}

private struct ActiveTerminalView: View {
  @Bindable var sessionManager: SessionManager
  let onDismiss: () -> Void

  var body: some View {
    if let session = sessionManager.activeSession {
      NavigationStack {
        TerminalContainerView(
          sshManager: session.sshManager,
          onDisconnect: {
            sessionManager.disconnectSession(session.id)
            onDismiss()
          }
        )
        .navigationTitle(session.config.resolvedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              onDismiss()
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                Text("Sessions")
              }
            }
          }

          ToolbarItem(placement: .topBarTrailing) {
            Button("Disconnect") {
              sessionManager.disconnectSession(session.id)
              onDismiss()
            }
            .foregroundStyle(.red)
          }
        }
      }
    }
  }
}
