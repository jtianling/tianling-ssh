import Foundation
import Citadel
import Crypto
import GameController
import NIO
import NIOSSH
import SwiftTerm
import UIKit

enum ConnectionState: Equatable {
  case disconnected
  case connecting
  case connected
  case failed(String)

  static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
    switch (lhs, rhs) {
    case (.disconnected, .disconnected),
         (.connecting, .connecting),
         (.connected, .connected):
      return true

    case (.failed(let a), .failed(let b)):
      return a == b

    default:
      return false

    }
  }
}

@Observable
@MainActor
final class SSHManager {
  var connectionState: ConnectionState = .disconnected
  let terminalView: SwiftTerm.TerminalView

  private var client: SSHClient?
  private var inputContinuation: AsyncStream<Data>.Continuation?
  private var sessionTask: Task<Void, Never>?
  private var disconnectContinuation: AsyncStream<Void>.Continuation?
  private var ttyWriter: TTYStdinWriter?

  private var savedAccessoryView: UIView?
  @ObservationIgnored
  private nonisolated(unsafe) var keyboardConnectObserver: (any NSObjectProtocol)?
  @ObservationIgnored
  private nonisolated(unsafe) var keyboardDisconnectObserver: (any NSObjectProtocol)?

  init() {
    let view = SwiftTerm.TerminalView(frame: .zero, font: nil)
    view.nativeBackgroundColor = .black
    self.terminalView = view
    view.terminalDelegate = self

    savedAccessoryView = view.inputAccessoryView
    updateAccessoryForKeyboardState()

    keyboardConnectObserver = NotificationCenter.default.addObserver(
      forName: .GCKeyboardDidConnect,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.updateAccessoryForKeyboardState()
      }
    }

    keyboardDisconnectObserver = NotificationCenter.default.addObserver(
      forName: .GCKeyboardDidDisconnect,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.updateAccessoryForKeyboardState()
      }
    }
  }

  deinit {
    if let observer = keyboardConnectObserver {
      NotificationCenter.default.removeObserver(observer)
    }

    if let observer = keyboardDisconnectObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func updateAccessoryForKeyboardState() {
    let hasExternalKeyboard = GCKeyboard.coalesced != nil
    terminalView.inputAccessoryView = hasExternalKeyboard ? nil : savedAccessoryView
    terminalView.reloadInputViews()
  }

  func connect(
    host: String,
    port: Int,
    username: String,
    password: String,
    startupScript: String = ""
  ) async {
    let authMethod = SSHAuthenticationMethod.passwordBased(
      username: username,
      password: password
    )
    await connectWith(
      host: host,
      port: port,
      authenticationMethod: authMethod,
      startupScript: startupScript
    )
  }

  func connectWithKeyFile(
    host: String,
    port: Int,
    username: String,
    privateKeyContent: String,
    startupScript: String = ""
  ) async {
    let authMethod: SSHAuthenticationMethod
    do {
      authMethod = try Self.buildKeyAuth(
        username: username,
        privateKeyContent: privateKeyContent
      )
    } catch {
      connectionState = .failed(String(describing: error))
      return
    }

    await connectWith(
      host: host,
      port: port,
      authenticationMethod: authMethod,
      startupScript: startupScript
    )
  }

  private static func normalizeKeyContent(
    _ content: String
  ) -> String {
    content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func buildKeyAuth(
    username: String,
    privateKeyContent: String
  ) throws -> SSHAuthenticationMethod {
    let normalized = normalizeKeyContent(privateKeyContent)
    let keyType = try SSHKeyDetection.detectPrivateKeyType(
      from: normalized
    )

    if keyType == .ed25519 {
      let privateKey = try OpenSSHEd25519Parser.parse(
        from: normalized
      )
      return .ed25519(
        username: username,
        privateKey: privateKey
      )
    }

    if keyType == .rsa {
      let privateKey = try Insecure.RSA.PrivateKey(
        sshRsa: normalized
      )
      return .rsa(
        username: username,
        privateKey: privateKey
      )
    }

    throw KeyFileError.unsupportedKeyType(keyType.rawValue)
  }

  private func connectWith(
    host: String,
    port: Int,
    authenticationMethod: SSHAuthenticationMethod,
    startupScript: String = ""
  ) async {
    terminalView.getTerminal().resetToInitialState()
    connectionState = .connecting

    do {
      let client = try await SSHClient.connect(
        host: host,
        port: port,
        authenticationMethod: authenticationMethod,
        hostKeyValidator: .acceptAnything(),
        reconnect: .never
      )
      self.client = client
      connectionState = .connected
      startShellSession(startupScript: startupScript)
    } catch {
      connectionState = .failed(error.localizedDescription)
    }
  }

  func disconnect() {
    disconnectContinuation?.yield()
    disconnectContinuation?.finish()
    disconnectContinuation = nil
    inputContinuation?.finish()
    inputContinuation = nil
    sessionTask?.cancel()
    sessionTask = nil
    ttyWriter = nil

    Task {
      try? await client?.close()
      client = nil
    }

    connectionState = .disconnected
  }

  func sendBytes(_ bytes: [UInt8]) {
    inputContinuation?.yield(Data(bytes))
  }

  private func startShellSession(startupScript: String = "") {
    guard let client else {
      return
    }

    let (inputStream, inputCont) = AsyncStream<Data>.makeStream()
    self.inputContinuation = inputCont

    let (disconnectStream, disconnectCont) = AsyncStream<Void>.makeStream()
    self.disconnectContinuation = disconnectCont

    let scriptLines = startupScript
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

    if !scriptLines.isEmpty {
      let continuation = inputCont
      Task {
        try? await Task.sleep(for: .milliseconds(500))

        for line in scriptLines {
          guard !Task.isCancelled else {
            return
          }

          let command = line + "\n"
          if let data = command.data(using: .utf8) {
            continuation.yield(data)
          }

          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    }

    sessionTask = Task { [weak self] in
      guard let strongSelf = self else {
        return
      }

      do {
        let initialSize = await MainActor.run {
          (
            strongSelf.terminalView.getTerminal().cols,
            strongSelf.terminalView.getTerminal().rows
          )
        }

        try await client.withPTY(
          SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: initialSize.0,
            terminalRowHeight: initialSize.1,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
          )
        ) { ttyOutput, ttyStdinWriter in
          await MainActor.run {
            strongSelf.ttyWriter = ttyStdinWriter
          }
          strongSelf.syncTerminalSize(
            writer: ttyStdinWriter,
            cols: initialSize.0,
            rows: initialSize.1
          )
          await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
              do {
                for try await chunk in ttyOutput {
                  guard !Task.isCancelled else {
                    return
                  }

                  let buffer: ByteBuffer
                  switch chunk {
                  case .stdout(let buf):
                    buffer = buf

                  case .stderr(let buf):
                    buffer = buf

                  }

                  let bytes = Array(buffer.readableBytesView)
                  guard !bytes.isEmpty else {
                    continue
                  }

                  strongSelf.terminalView.feed(byteArray: bytes[...])
                }
              } catch {
                if strongSelf.connectionState == .connected {
                  strongSelf.connectionState = .failed(
                    error.localizedDescription
                  )
                }
              }
            }

            group.addTask {
              for await data in inputStream {
                guard !Task.isCancelled else {
                  return
                }

                let buffer = ByteBuffer(data: data)
                try? await ttyStdinWriter.write(buffer)
              }
            }

            group.addTask {
              for await _ in disconnectStream {
                return
              }
            }

            await group.next()
            group.cancelAll()
          }
        }
      } catch {
        await MainActor.run {
          if strongSelf.connectionState == .connected {
            strongSelf.connectionState = .failed(
              error.localizedDescription
            )
          }
        }
      }
    }
  }

  private func syncTerminalSize(
    writer: TTYStdinWriter,
    cols: Int,
    rows: Int
  ) {
    Task {
      try? await writer.changeSize(
        cols: cols,
        rows: rows,
        pixelWidth: 0,
        pixelHeight: 0
      )
    }
  }
}

extension SSHManager: SwiftTerm.TerminalViewDelegate {
  func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
    inputContinuation?.yield(Data(data))
  }

  func sizeChanged(
    source: SwiftTerm.TerminalView,
    newCols: Int,
    newRows: Int
  ) {
    guard let ttyWriter else {
      return
    }

    syncTerminalSize(writer: ttyWriter, cols: newCols, rows: newRows)
  }

  func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
  }

  func hostCurrentDirectoryUpdate(
    source: SwiftTerm.TerminalView,
    directory: String?
  ) {
  }

  func scrolled(source: SwiftTerm.TerminalView, position: Double) {
  }

  func requestOpenLink(
    source: SwiftTerm.TerminalView,
    link: String,
    params: [String: String]
  ) {
  }

  func bell(source: SwiftTerm.TerminalView) {
  }

  func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
  }

  func iTermContent(
    source: SwiftTerm.TerminalView,
    content: ArraySlice<UInt8>
  ) {
  }

  func rangeChanged(
    source: SwiftTerm.TerminalView,
    startY: Int,
    endY: Int
  ) {
  }
}

enum KeyFileError: LocalizedError {
  case unsupportedKeyType(String)
  case invalidKeyFormat(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedKeyType(let type):
      return "Unsupported key type: \(type). "
        + "Only Ed25519 and RSA are supported."

    case .invalidKeyFormat(let detail):
      return "Invalid key format: \(detail)"

    }
  }
}

/// Parses unencrypted OpenSSH ed25519 private keys.
/// Workaround for Citadel 0.12.0 padding validation bug
/// where paddingLength == blockSize is incorrectly rejected.
enum OpenSSHEd25519Parser {
  static func parse(
    from content: String
  ) throws -> Curve25519.Signing.PrivateKey {
    let data = try decodeBase64Payload(from: content)
    var offset = 0

    try checkMagic(data: data, offset: &offset)
    try checkUnencrypted(data: data, offset: &offset)
    try skipKDFOptions(data: data, offset: &offset)
    try checkSingleKey(data: data, offset: &offset)
    try skipPublicKeySection(data: data, offset: &offset)

    _ = try readUInt32(
      from: data, at: &offset
    )
    try checkChecksums(data: data, offset: &offset)
    try checkKeyType(data: data, offset: &offset)

    _ = try readBytes(from: data, at: &offset)

    let privBlob = try readBytes(from: data, at: &offset)

    guard privBlob.count == 64 else {
      throw KeyFileError.invalidKeyFormat(
        "Expected 64-byte ed25519 key blob, got \(privBlob.count)"
      )
    }

    return try Curve25519.Signing.PrivateKey(
      rawRepresentation: privBlob.prefix(32)
    )
  }

  private static func decodeBase64Payload(
    from content: String
  ) throws -> Data {
    var key = content.replacingOccurrences(of: "\n", with: "")
    let prefix = "-----BEGIN OPENSSH PRIVATE KEY-----"
    let suffix = "-----END OPENSSH PRIVATE KEY-----"

    guard key.hasPrefix(prefix),
          key.hasSuffix(suffix)
    else {
      throw KeyFileError.invalidKeyFormat("Missing PEM boundaries")
    }

    key.removeFirst(prefix.count)
    key.removeLast(suffix.count)

    guard let data = Data(base64Encoded: key) else {
      throw KeyFileError.invalidKeyFormat("Invalid base64 payload")
    }

    return data
  }

  private static func checkMagic(
    data: Data,
    offset: inout Int
  ) throws {
    let magic: [UInt8] = Array("openssh-key-v1".utf8) + [0]

    guard offset + magic.count <= data.count,
          Array(data[offset..<offset + magic.count]) == magic
    else {
      throw KeyFileError.invalidKeyFormat("Missing openssh-key-v1 magic")
    }

    offset += magic.count
  }

  private static func checkUnencrypted(
    data: Data,
    offset: inout Int
  ) throws {
    let cipher = try readString(from: data, at: &offset)

    guard cipher == "none" else {
      throw KeyFileError.invalidKeyFormat(
        "Encrypted keys are not supported (cipher: \(cipher))"
      )
    }

    let kdf = try readString(from: data, at: &offset)

    guard kdf == "none" else {
      throw KeyFileError.invalidKeyFormat(
        "Encrypted keys are not supported (kdf: \(kdf))"
      )
    }
  }

  private static func skipKDFOptions(
    data: Data,
    offset: inout Int
  ) throws {
    let len = try readUInt32(from: data, at: &offset)
    offset += Int(len)
  }

  private static func checkSingleKey(
    data: Data,
    offset: inout Int
  ) throws {
    let count = try readUInt32(from: data, at: &offset)

    guard count == 1 else {
      throw KeyFileError.invalidKeyFormat(
        "Expected 1 key, got \(count)"
      )
    }
  }

  private static func skipPublicKeySection(
    data: Data,
    offset: inout Int
  ) throws {
    let len = try readUInt32(from: data, at: &offset)
    offset += Int(len)
  }

  private static func checkChecksums(
    data: Data,
    offset: inout Int
  ) throws {
    let check0 = try readUInt32(from: data, at: &offset)
    let check1 = try readUInt32(from: data, at: &offset)

    guard check0 == check1 else {
      throw KeyFileError.invalidKeyFormat("Checksum mismatch")
    }
  }

  private static func checkKeyType(
    data: Data,
    offset: inout Int
  ) throws {
    let keyType = try readString(from: data, at: &offset)

    guard keyType == "ssh-ed25519" else {
      throw KeyFileError.invalidKeyFormat(
        "Expected ssh-ed25519, got \(keyType)"
      )
    }
  }

  private static func readUInt32(
    from data: Data,
    at offset: inout Int
  ) throws -> UInt32 {
    guard offset + 4 <= data.count else {
      throw KeyFileError.invalidKeyFormat("Unexpected end of data")
    }

    let value = UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
    offset += 4
    return value
  }

  private static func readString(
    from data: Data,
    at offset: inout Int
  ) throws -> String {
    let bytes = try readBytes(from: data, at: &offset)

    guard let str = String(data: bytes, encoding: .utf8) else {
      throw KeyFileError.invalidKeyFormat("Invalid UTF-8 string")
    }

    return str
  }

  private static func readBytes(
    from data: Data,
    at offset: inout Int
  ) throws -> Data {
    let length = try readUInt32(from: data, at: &offset)
    let end = offset + Int(length)

    guard end <= data.count else {
      throw KeyFileError.invalidKeyFormat("Unexpected end of data")
    }

    let bytes = data[offset..<end]
    offset = end
    return bytes
  }
}
