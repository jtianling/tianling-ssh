import SwiftUI

struct SessionListView: View {
  @Bindable var sessionManager: SessionManager
  @State private var showingNewConnection = false
  @State private var editingSession: SSHSession?

  var body: some View {
    List {
      if sessionManager.sessions.isEmpty {
        ContentUnavailableView(
          "No Sessions",
          systemImage: "terminal",
          description: Text("Tap + to create a new SSH session")
        )
      }

      ForEach(sessionManager.sessions) { session in
        SessionRowView(
          session: session,
          isActive: session.id == sessionManager.activeSessionID
        )
        .contentShape(Rectangle())
        .onTapGesture {
          sessionManager.selectSession(session.id)
        }
        .contextMenu {
          Button {
            editingSession = session
          } label: {
            Label("Edit", systemImage: "pencil")
          }

          Button {
            sessionManager.duplicateSession(session.id)
          } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
          }

          if case .connected = session.sshManager.connectionState {
            Button {
              sessionManager.disconnectSession(session.id)
            } label: {
              Label("Disconnect", systemImage: "bolt.slash")
            }
          }

          Button(role: .destructive) {
            sessionManager.removeSession(session.id)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      .onDelete { indexSet in
        let idsToRemove = indexSet.map {
          sessionManager.sessions[$0].id
        }
        for id in idsToRemove {
          sessionManager.removeSession(id)
        }
      }
    }
    .navigationTitle("Sessions")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showingNewConnection = true
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(isPresented: $showingNewConnection) {
      NavigationStack {
        ConnectionConfigView(
          onConnect: { config in
            showingNewConnection = false
            Task {
              _ = await sessionManager.createSession(
                config: config
              )
            }
          },
          onCancel: {
            showingNewConnection = false
          }
        )
      }
    }
    .sheet(item: $editingSession) { session in
      NavigationStack {
        ConnectionConfigView(
          onConnect: { config in
            let oldID = session.id
            editingSession = nil
            Task {
              await sessionManager.replaceSession(
                oldID, with: config
              )
            }
          },
          onSave: { config in
            sessionManager.updateSession(session.id, with: config)
            editingSession = nil
          },
          onCancel: {
            editingSession = nil
          },
          initialConfig: session.config,
          title: "Edit Connection"
        )
      }
    }
  }
}

private struct SessionRowView: View {
  let session: SSHSession
  let isActive: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(session.displayName)
          .font(.headline)

        HStack(spacing: 4) {
          stateIndicator
          stateText
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if isActive {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.blue)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var stateIndicator: some View {
    Circle()
      .fill(stateColor)
      .frame(width: 8, height: 8)
  }

  private var stateColor: Color {
    switch session.sshManager.connectionState {
    case .disconnected:
      return .gray

    case .connecting:
      return .orange

    case .connected:
      return .green

    case .failed:
      return .red

    }
  }

  private var stateText: Text {
    switch session.sshManager.connectionState {
    case .disconnected:
      return Text("Disconnected")

    case .connecting:
      return Text("Connecting...")

    case .connected:
      return Text("Connected")

    case .failed(let error):
      return Text("Failed: \(error)")

    }
  }
}
