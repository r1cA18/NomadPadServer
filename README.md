# NomadPad Server

[日本語版 README はこちら](README.ja.md)

**Turn your iPhone/iPad into a wireless trackpad for your Mac.**

NomadPad Server is the macOS companion app that receives input from the [NomadPad iOS app](https://apps.apple.com/app/nomadpad) and controls your Mac's mouse, keyboard, and gestures.

## Features

- Wireless trackpad control
- Mouse movement, clicks, and scrolling
- Keyboard input support
- Multi-finger gestures (right-click, scroll, Spaces switching)
- Secure connection via TLS with pre-shared key (QR code pairing)

## Requirements

- macOS 14.0 or later
- Accessibility permission (for mouse/keyboard control)

## Installation

1. Download the latest release from [Releases](https://github.com/r1cA18/NomadPadServer/releases)
2. Move `NomadPadServer.app` to your Applications folder
3. Launch the app
4. Grant Accessibility permission when prompted
5. Scan the QR code with the NomadPad iOS app

## Building from Source

```bash
git clone https://github.com/r1cA18/NomadPadServer.git
cd NomadPadServer
open NomadPadServer/NomadPadServer.xcodeproj
```

Build and run with Xcode.

## Architecture

- **NomadPadServer**: Main menu bar app that handles network connections and input processing
- **NomadPadHelper**: Login item helper for system-level keyboard shortcuts (Spaces switching)
- **Shared**: Common protocol definitions

## Security

- All connections are encrypted with TLS using pre-shared keys
- Pairing is done via QR code (no network transmission of keys)
- Keys are stored securely in macOS Keychain

## License

MIT License - See [LICENSE](LICENSE) for details.

## Related

- [NomadPad iOS App](https://apps.apple.com/app/nomadpad) - The iOS companion app
