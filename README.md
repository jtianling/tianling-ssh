# Tianling SSH

A native iOS SSH client built with SwiftUI.  Terminal emulation powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

[中文文档](./README_CN.md)

## Why Tianling SSH?

This app has fewer features and a simpler design compared to other iOS SSH clients.  What sets it apart is **first-class iPad external keyboard support**, including **Chinese (CJK) input methods**.

Many iOS SSH apps — even popular commercial ones — have issues with external keyboards on iPad: modifier keys not working correctly, IME composition interrupted, or Chinese input simply broken.  Tianling SSH focuses on getting these fundamentals right so you can work comfortably on an iPad with a physical keyboard.

## Features

- **Multiple Authentication Methods** - Password and SSH key (Ed25519 / RSA) support, with key file import or direct paste
- **Multi-Session Management** - Create, switch, edit, and delete multiple SSH sessions simultaneously
- **Terminal Emulator** - Full VT100 / xterm compatibility powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with CoreText rendering, ANSI colors, selection, and alternate-buffer support
- **Keyboard Accessory Bar** - SwiftTerm's built-in accessory bar over the software keyboard with Esc, Ctrl, Tab, F1-F10, and common symbols
- **Startup Scripts** - Configure commands to run automatically after connection
- **Session Persistence** - Saved sessions are restored across app launches

## Requirements

- iOS 17.0+
- Xcode 15+
- Swift 5.0+

## Getting Started

1. Clone the repository:

```bash
git clone https://github.com/jtianling/tianling-ssh.git
cd tianling-ssh
```

2. Regenerate and open the Xcode project:

```bash
xcodegen generate
open tianling-ssh.xcodeproj
```

3. Xcode will automatically resolve the Swift Package dependencies.  Build and run on a simulator or device.

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - VT100 / xterm terminal emulator and UIKit view
- [Citadel](https://github.com/orlandos-nl/Citadel) - SSH client library built on SwiftNIO

## Project Structure

```
App/
  TLSSHApp.swift             # App entry point
  ContentView.swift           # Root navigation and session routing
Connection/
  ConnectionConfigView.swift  # Connection form (host, auth, startup script)
Session/
  SessionManager.swift        # Session lifecycle and persistence (@MainActor)
  SessionListView.swift       # Session list UI
SSH/
  SSHManager.swift            # SSH connection, PTY, SwiftTerm integration (@MainActor)
Terminal/
  TerminalContainerView.swift # Terminal chrome and overlays
  SwiftTermBridgeView.swift   # UIViewRepresentable wrapping SwiftTerm.TerminalView
```

## Acknowledgements

This project relies on [Citadel](https://github.com/orlandos-nl/Citadel) by Joannis Orlandos for SSH protocol implementation, and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza for terminal emulation and rendering.

## License

This project is licensed under the [MIT License](./LICENSE).
