import SwiftUI

enum AuthType: String, CaseIterable, Codable {
  case password
  case keyFile

  var displayName: String {
    switch self {
    case .password:
      return "Password"

    case .keyFile:
      return "Key File"

    }
  }
}

enum KeyInputMode: String, CaseIterable, Codable {
  case file
  case paste

  var displayName: String {
    switch self {
    case .file:
      return "Import File"

    case .paste:
      return "Paste Text"

    }
  }
}

struct ConnectionConfig: Codable {
  let host: String
  let port: Int
  let username: String
  let authType: AuthType
  let password: String
  let privateKeyContent: String
  let startupScript: String
  let keyInputMode: KeyInputMode?
  let sessionName: String?

  var resolvedTitle: String {
    let trimmed = sessionName?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if !trimmed.isEmpty {
      return trimmed
    }

    return host
  }
}

struct ConnectionConfigView: View {
  let onConnect: (ConnectionConfig) -> Void
  var onSave: ((ConnectionConfig) -> Void)?
  var onCancel: (() -> Void)?
  var lastError: String?
  var title: String

  @State private var host: String
  @State private var port: String
  @State private var username: String
  @State private var password: String
  @State private var authType: AuthType
  @State private var privateKeyContent: String
  @State private var keyFileName: String
  @State private var keyInputMode: KeyInputMode
  @State private var pastedKeyText: String
  @State private var showingFileImporter = false
  @State private var startupScript: String
  @State private var sessionName: String
  @State private var isConnecting = false

  init(
    onConnect: @escaping (ConnectionConfig) -> Void,
    onSave: ((ConnectionConfig) -> Void)? = nil,
    onCancel: (() -> Void)? = nil,
    lastError: String? = nil,
    initialConfig: ConnectionConfig? = nil,
    title: String = "New Connection"
  ) {
    self.onConnect = onConnect
    self.onSave = onSave
    self.onCancel = onCancel
    self.lastError = lastError
    self.title = title
    _host = State(initialValue: initialConfig?.host ?? "")
    _port = State(
      initialValue: initialConfig.map { String($0.port) } ?? "22"
    )
    _username = State(initialValue: initialConfig?.username ?? "")
    _password = State(initialValue: initialConfig?.password ?? "")
    _authType = State(
      initialValue: initialConfig?.authType ?? .password
    )

    let restoredMode = initialConfig?.keyInputMode ?? .file
    let restoredKey = initialConfig?.privateKeyContent ?? ""

    switch restoredMode {
    case .file:
      _privateKeyContent = State(initialValue: restoredKey)
      _pastedKeyText = State(initialValue: "")

    case .paste:
      _privateKeyContent = State(initialValue: "")
      _pastedKeyText = State(initialValue: restoredKey)

    }

    _keyFileName = State(initialValue: "")
    _keyInputMode = State(initialValue: restoredMode)
    _startupScript = State(
      initialValue: initialConfig?.startupScript ?? ""
    )
    _sessionName = State(initialValue: initialConfig?.sessionName ?? "")
  }

  private var isFormValid: Bool {
    let hasHost = !host
      .trimmingCharacters(in: .whitespaces).isEmpty
    let hasUsername = !username
      .trimmingCharacters(in: .whitespaces).isEmpty

    guard hasHost,
          hasUsername
    else {
      return false
    }

    switch authType {
    case .password:
      return true

    case .keyFile:
      switch keyInputMode {
      case .file:
        return !privateKeyContent.isEmpty

      case .paste:
        return !pastedKeyText
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty

      }

    }
  }

  var body: some View {
    Form {
      Section("Session Name") {
        TextField("Optional", text: $sessionName)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      }

      Section("Server") {
        TextField("Host", text: $host)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)

        TextField("Port", text: $port)
          .keyboardType(.numberPad)
      }

      Section("Authentication") {
        Picker("Method", selection: $authType) {
          ForEach(AuthType.allCases, id: \.self) { type in
            Text(type.displayName).tag(type)
          }
        }
        .pickerStyle(.segmented)

        TextField("Username", text: $username)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)

        switch authType {
        case .password:
          SecureField("Password", text: $password)

        case .keyFile:
          keyInputModeSection

        }
      }

      Section("Startup Script") {
        TextEditor(text: $startupScript)
          .font(.system(.body, design: .monospaced))
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .frame(minHeight: 100)
      }

      if let lastError {
        Section {
          Text(lastError)
            .foregroundStyle(.red)
            .font(.caption)
        }
      }

      Section {
        Button {
          performConnect()
        } label: {
          HStack {
            Spacer()
            if isConnecting {
              ProgressView()
                .padding(.trailing, 8)
              Text("Connecting...")
            } else {
              Text("Connect")
            }
            Spacer()
          }
        }
        .disabled(!isFormValid || isConnecting)
      }
    }
    .navigationTitle(title)
    .toolbar {
      if let onCancel {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
        }
      }

      if onSave != nil {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            performSave()
          }
          .disabled(isConnecting)
        }
      }
    }
    .fileImporter(
      isPresented: $showingFileImporter,
      allowedContentTypes: [.data, .text, .plainText],
      allowsMultipleSelection: false
    ) { result in
      handleFileImport(result)
    }
  }

  private var keyInputModeSection: some View {
    Group {
      Picker("Key Source", selection: $keyInputMode) {
        ForEach(KeyInputMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      switch keyInputMode {
      case .file:
        keyFileRow

      case .paste:
        pastedKeyRow

      }
    }
  }

  private var keyFileRow: some View {
    Button {
      showingFileImporter = true
    } label: {
      HStack {
        Image(systemName: "doc.badge.plus")
        if keyFileName.isEmpty {
          Text("Select Key File")
            .foregroundStyle(.secondary)
        } else {
          Text(keyFileName)
        }
        Spacer()
        if !privateKeyContent.isEmpty {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
    }
  }

  private var pastedKeyRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextEditor(text: $pastedKeyText)
        .font(.system(.caption, design: .monospaced))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .frame(minHeight: 120)
        .overlay(alignment: .topLeading) {
          if pastedKeyText.isEmpty {
            Text("Paste private key here...")
              .foregroundStyle(.tertiary)
              .font(.system(.caption, design: .monospaced))
              .padding(.top, 8)
              .padding(.leading, 4)
              .allowsHitTesting(false)
          }
        }
    }
  }

  private var resolvedPrivateKeyContent: String {
    switch keyInputMode {
    case .file:
      return privateKeyContent

    case .paste:
      return pastedKeyText
        .trimmingCharacters(in: .whitespacesAndNewlines)

    }
  }

  private func currentConfig() -> ConnectionConfig {
    let trimmedSessionName = sessionName
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return ConnectionConfig(
      host: host.trimmingCharacters(in: .whitespaces),
      port: Int(port) ?? 22,
      username: username.trimmingCharacters(in: .whitespaces),
      authType: authType,
      password: password,
      privateKeyContent: resolvedPrivateKeyContent,
      startupScript: startupScript,
      keyInputMode: authType == .keyFile ? keyInputMode : nil,
      sessionName: trimmedSessionName.isEmpty ? nil : trimmedSessionName
    )
  }

  private func performConnect() {
    isConnecting = true
    onConnect(currentConfig())
  }

  private func performSave() {
    onSave?(currentConfig())
  }

  private func handleFileImport(
    _ result: Result<[URL], Error>
  ) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        return
      }

      guard url.startAccessingSecurityScopedResource() else {
        return
      }

      defer { url.stopAccessingSecurityScopedResource() }

      do {
        let content = try String(contentsOf: url, encoding: .utf8)
        privateKeyContent = content
        keyFileName = url.lastPathComponent
      } catch {
        privateKeyContent = ""
        keyFileName = ""
      }

    case .failure:
      privateKeyContent = ""
      keyFileName = ""

    }
  }
}
