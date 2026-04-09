import XCTest
@testable import TLSSH

final class ConnectionConfigTests: XCTestCase {
  func test_resolvedTitle_returnsHost_whenSessionNameIsNil() {
    let config = makeConfig(host: "server.example.com", sessionName: nil)

    XCTAssertEqual(config.resolvedTitle, "server.example.com")
  }

  func test_resolvedTitle_returnsSessionName_whenProvided() {
    let config = makeConfig(host: "server.example.com", sessionName: "Production")

    XCTAssertEqual(config.resolvedTitle, "Production")
  }

  func test_resolvedTitle_returnsHost_whenSessionNameIsEmptyString() {
    let config = makeConfig(host: "server.example.com", sessionName: "")

    XCTAssertEqual(config.resolvedTitle, "server.example.com")
  }

  func test_resolvedTitle_returnsHost_whenSessionNameIsWhitespace() {
    let config = makeConfig(host: "server.example.com", sessionName: "   \n\t")

    XCTAssertEqual(config.resolvedTitle, "server.example.com")
  }

  func test_decode_acceptsLegacyJSONWithoutSessionNameField() throws {
    let legacyJSON = """
    {
      "host": "legacy.example.com",
      "port": 22,
      "username": "user",
      "authType": "password",
      "password": "pw",
      "privateKeyContent": "",
      "startupScript": ""
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self,
      from: legacyJSON
    )

    XCTAssertNil(decoded.sessionName)
    XCTAssertEqual(decoded.resolvedTitle, "legacy.example.com")
  }

  func test_codable_roundTripPreservesSessionName() throws {
    let original = makeConfig(host: "h.example.com", sessionName: "Prod DB")

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self,
      from: data
    )

    XCTAssertEqual(decoded.sessionName, "Prod DB")
    XCTAssertEqual(decoded.resolvedTitle, "Prod DB")
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
