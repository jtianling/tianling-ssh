import XCTest
@testable import TLSSH

@MainActor
final class SessionManagerTests: XCTestCase {
  private var tempURL: URL!

  override func setUp() async throws {
    try await super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-manager-tests-\(UUID().uuidString).json")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempURL)
    try await super.tearDown()
  }

  func test_updateSession_replacesConfigInPlace() {
    let manager = SessionManager(storageURL: tempURL)
    let original = makeConfig(host: "old.example.com", sessionName: nil)
    let session = SSHSession(config: original, sshManager: SSHManager())
    manager.sessions.append(session)

    let updated = makeConfig(host: "old.example.com", sessionName: "Renamed")
    manager.updateSession(session.id, with: updated)

    XCTAssertEqual(manager.sessions.count, 1)
    XCTAssertEqual(manager.sessions[0].id, session.id)
    XCTAssertEqual(manager.sessions[0].config.sessionName, "Renamed")
  }

  func test_updateSession_preservesSSHManagerInstance() {
    let manager = SessionManager(storageURL: tempURL)
    let sshManager = SSHManager()
    let session = SSHSession(
      config: makeConfig(host: "x.example.com"),
      sshManager: sshManager
    )
    manager.sessions.append(session)

    manager.updateSession(session.id, with: makeConfig(host: "y.example.com"))

    XCTAssertTrue(manager.sessions[0].sshManager === sshManager)
  }

  func test_updateSession_isNoOp_whenSessionIDIsUnknown() {
    let manager = SessionManager(storageURL: tempURL)
    let session = SSHSession(
      config: makeConfig(host: "x.example.com"),
      sshManager: SSHManager()
    )
    manager.sessions.append(session)

    manager.updateSession(UUID(), with: makeConfig(host: "y.example.com"))

    XCTAssertEqual(manager.sessions.count, 1)
    XCTAssertEqual(manager.sessions[0].config.host, "x.example.com")
  }

  private func makeConfig(
    host: String = "host.example.com",
    sessionName: String? = nil
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: host,
      port: 22,
      username: "user",
      authType: .password,
      password: "pw",
      privateKeyContent: "",
      startupScript: "",
      keyInputMode: nil,
      sessionName: sessionName
    )
  }
}
