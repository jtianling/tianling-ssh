import Foundation

struct SSHSession: Identifiable {
  let id: UUID
  let host: String
  let port: Int
  let username: String
  let config: ConnectionConfig
  let sshManager: SSHManager
  let createdAt: Date

  init(
    id: UUID = UUID(),
    config: ConnectionConfig,
    sshManager: SSHManager
  ) {
    self.id = id
    self.host = config.host
    self.port = config.port
    self.username = config.username
    self.config = config
    self.sshManager = sshManager
    self.createdAt = Date()
  }

  var displayName: String {
    "\(username)@\(host):\(port)"
  }
}

@Observable
@MainActor
final class SessionManager {
  var sessions: [SSHSession] = []
  var activeSessionID: UUID?

  private let storageURL: URL

  nonisolated static let defaultStorageURL: URL = {
    let dir = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    try? FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("saved-sessions.json")
  }()

  var activeSession: SSHSession? {
    guard let activeSessionID else {
      return nil
    }

    return sessions.first { $0.id == activeSessionID }
  }

  init(storageURL: URL = SessionManager.defaultStorageURL) {
    self.storageURL = storageURL
    loadSessions()
  }

  func createSession(config: ConnectionConfig) async -> SSHSession {
    let sshManager = SSHManager()
    let session = SSHSession(
      config: config,
      sshManager: sshManager
    )
    sessions.append(session)
    activeSessionID = session.id
    persistSessions()
    await connectSession(sshManager: sshManager, config: config)
    return session
  }

  func replaceSession(
    _ oldID: UUID,
    with config: ConnectionConfig
  ) async {
    removeSession(oldID)
    _ = await createSession(config: config)
  }

  func updateSession(
    _ id: UUID,
    with config: ConnectionConfig
  ) {
    guard let index = sessions.firstIndex(
      where: { $0.id == id }
    ) else {
      return
    }

    let existing = sessions[index]
    sessions[index] = SSHSession(
      id: existing.id,
      config: config,
      sshManager: existing.sshManager
    )
    persistSessions()
  }

  func duplicateSession(_ id: UUID) {
    guard let source = sessions.first(
      where: { $0.id == id }
    ) else {
      return
    }

    let sshManager = SSHManager()
    let duplicate = SSHSession(
      config: source.config,
      sshManager: sshManager
    )
    sessions.append(duplicate)
    persistSessions()
  }

  func selectSession(_ id: UUID) {
    activeSessionID = id

    guard let session = sessions.first(
      where: { $0.id == id }
    ) else {
      return
    }

    switch session.sshManager.connectionState {
    case .disconnected, .failed:
      Task {
        await connectSession(
          sshManager: session.sshManager,
          config: session.config
        )
      }

    default:
      break

    }
  }

  func disconnectSession(_ id: UUID) {
    guard let session = sessions.first(
      where: { $0.id == id }
    ) else {
      return
    }

    session.sshManager.disconnect()
  }

  func removeSession(_ id: UUID) {
    guard let index = sessions.firstIndex(
      where: { $0.id == id }
    ) else {
      return
    }

    sessions[index].sshManager.disconnect()
    sessions.remove(at: index)

    if activeSessionID == id {
      activeSessionID = sessions.last?.id
    }

    persistSessions()
  }

  func removeAllSessions() {
    for session in sessions {
      session.sshManager.disconnect()
    }
    sessions.removeAll()
    activeSessionID = nil
    persistSessions()
  }

  private func connectSession(
    sshManager: SSHManager,
    config: ConnectionConfig
  ) async {
    switch config.authType {
    case .password:
      await sshManager.connect(
        host: config.host,
        port: config.port,
        username: config.username,
        password: config.password,
        startupScript: config.startupScript
      )

    case .keyFile:
      await sshManager.connectWithKeyFile(
        host: config.host,
        port: config.port,
        username: config.username,
        privateKeyContent: config.privateKeyContent,
        startupScript: config.startupScript
      )

    }
  }

  // MARK: - Persistence

  private func loadSessions() {
    guard FileManager.default.fileExists(
      atPath: storageURL.path
    ) else {
      return
    }

    guard let data = try? Data(
      contentsOf: storageURL
    ) else {
      return
    }

    guard let saved = try? JSONDecoder().decode(
      [SavedSession].self,
      from: data
    ) else {
      return
    }

    sessions = saved.map { entry in
      SSHSession(
        id: entry.id,
        config: entry.config,
        sshManager: SSHManager()
      )
    }
  }

  private func persistSessions() {
    let saved = sessions.map {
      SavedSession(id: $0.id, config: $0.config)
    }

    guard let data = try? JSONEncoder().encode(saved) else {
      return
    }

    try? data.write(to: storageURL)
  }
}

private struct SavedSession: Codable {
  let id: UUID
  let config: ConnectionConfig
}
