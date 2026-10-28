# FaceID for macOS

Unlock your Mac's lock screen and screensaver with your face, using the built-in FaceTime camera or an external webcam.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Status](https://img.shields.io/badge/status-experimental-yellow)

> [!WARNING]
> **Security notice.** Mac cameras are 2D and have no TrueDepth depth sensor like the iPhone's.
> This project is therefore **less secure than Apple's Face ID** and may be defeated by sophisticated spoofing.
> Your password always keeps working, and FaceID **cannot unlock FileVault at boot**.

---

## Contents

- [Features](#features)
- [Project status](#project-status)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Building and testing](#building-and-testing)
- [Installation](#installation)
- [Using FaceID at the lock screen](#using-faceid-at-the-lock-screen)
- [Privacy and data handling](#privacy-and-data-handling)
- [Known limitations](#known-limitations)
- [Documentation](#documentation)
- [Third-party components](#third-party-components)

## Features

- **Face enrollment** from a menu bar app, with a guided multi-pose capture.
- **Liveness detection**: a natural blink plus a randomized head turn; still photos do not pass.
- **Fail-closed by design**: any error, timeout or mismatch falls back to the normal password prompt.
- **Lockout**: three consecutive failed scans disable face unlock until you unlock once with your password.
- **One-click off switch** in the menu bar.
- **On-device only**: face data is encrypted with a Secure Enclave key, never leaves the Mac,
  and the processes that handle it run in a sandbox with no network access.

## Project status

| Component | Status |
|---|---|
| `FaceIDCore` (Swift package) | ✅ Implemented, unit tested |
| `FaceIDAgent` (LaunchAgent + XPC) | ✅ Tested on a physical Mac (release, without plugin) and in a VM |
| `FaceIDApp` (menu bar app, enrollment) | ✅ Enrollment and test scans work on a physical Mac |
| `FaceIDBroker` (LaunchDaemon) | ✅ Relays plugin requests to the agent and monitors the plugin |
| `FaceIDAuthPlugin` (authorization plugin) | 🧪 Passed the VM test plan ([docs/plugin-vm-test.md](docs/plugin-vm-test.md)); not yet used for real unlocks on a physical Mac |
| `install.sh` / `uninstall.sh` / recovery guide | ✅ Fully tested in a VM, including Recovery Mode |
| Embedding model | ✅ SFace (Apache 2.0) — see [Models/README.md](Models/README.md) |
| `pam_faceid` (sudo) | ⏳ Optional, not started |
| FAR/FRR measurements | ⏳ Not measured yet; `matchThreshold` stays unchanged until they are |

> [!IMPORTANT]
> This is an experimental project. Always test lock-screen changes in a virtual machine first.

## Architecture

FaceID is split into small, separately signed components so that camera access, biometric
processing and lock-screen integration each stay in the narrowest possible context.

| Component | Runs as | Responsibility |
|---|---|---|
| **FaceIDAgent** | LaunchAgent, logged-in user | Camera, Vision face detection, Core ML embeddings, liveness, matching, encrypted template storage |
| **FaceIDApp** | Menu bar app, logged-in user | Enrollment UI, settings, on/off switch. Never touches the camera itself |
| **FaceIDBroker** | LaunchDaemon | Relays requests between the lock-screen plugin and the agent; restores the original authorization rule if the plugin goes missing |
| **FaceIDAuthPlugin** | Loaded by macOS at the lock screen | Asks for a face match and maps the answer to allow or "fall back to password" |
| **FaceIDCore** | Library | Shared logic: quality gate, liveness, matcher, template store, XPC contracts |

Every XPC connection is restricted by a code signing requirement, and only result codes and
status flags cross process boundaries — never images, embeddings or similarity scores.

```text
Sources/FaceIDCore/      Shared library (camera, detection, liveness, recognition, storage, XPC)
Apps/FaceIDAgent/        LaunchAgent and its sandbox profile
Apps/FaceIDApp/          Menu bar app
Apps/FaceIDBroker/       LaunchDaemon and its sandbox profile
Plugins/FaceIDAuthPlugin/ Authorization plugin (Objective-C) and rule files
Models/                  Embedding model conversion and license notice
Scripts/                 Build, install, uninstall and recovery
Tests/                   Unit and integration tests (mocks only, never the real camera)
docs/                    Security model, signing, and test plans
```

## Requirements

- macOS 14 Sonoma or later (developed and tested on macOS 27)
- Xcode with Swift 6
- A Mac with a Secure Enclave for release builds (Apple silicon or a T2 Intel Mac)
- A local code signing certificate — **no Apple Developer Program membership needed**
  (see [docs/local-signing.md](docs/local-signing.md))

## Building and testing

Build and run the test suite:

```bash
swift build
```

```bash
swift test
```

All tests use mocks and never open the real camera.

Build and sign the app, agent, broker and plugin into `dist/` (requires the local signing
certificate from [docs/local-signing.md](docs/local-signing.md)):

```bash
Scripts/build-app.sh
```

For virtual machines, which have no Secure Enclave, build the debug configuration:

```bash
BUILD_CONFIGURATION=debug Scripts/build-app.sh
```

## Installation

Install the agent and menu bar app only. This does not modify the lock screen:

```bash
sudo Scripts/install.sh
```

Installation backs up the original authorization rules first and leaves FaceID **disabled**
until you enroll your face and turn it on. The lock-screen plugin is a separate, opt-in step
that the installer refuses to perform outside a VM unless explicitly allowed; follow
[docs/plugin-vm-test.md](docs/plugin-vm-test.md) before enabling it.

Uninstall everything and restore the original rules:

```bash
sudo "/Library/Application Support/FaceID/uninstall.sh"
```

If anything goes wrong, see the recovery guide: [Scripts/recovery.md](Scripts/recovery.md).

## Using FaceID at the lock screen

With the plugin installed:

1. Wake the display and **press Return** at the lock screen (the password field may be empty).
   macOS evaluates the unlock rule only when you attempt to log in, not when the display wakes.
2. Look at the camera, blink, and turn your head slightly left and right. The direction is
   randomized to defeat recorded video, but the lock screen cannot show which way to turn.
3. If the scan fails, times out or the agent is unavailable, the password field appears as usual.
4. After three consecutive failures, only the password works until you unlock with it once.

Turn the feature off at any time with the face unlock switch at the top of the FaceID menu bar panel.

## Privacy and data handling

- Only encrypted face embeddings are stored — AES-GCM with a Secure Enclave key, in the
  Keychain with `WhenUnlockedThisDeviceOnly` access and **no iCloud sync**.
- No face images and no passwords are ever stored.
- Camera frames and embeddings exist only in `FaceIDAgent`'s memory; they never cross XPC and
  never leave the Mac.
- The agent and broker run under a kernel sandbox that denies all network access; release
  builds refuse to run if that isolation is missing.
- Release builds require a Secure Enclave.
- Deleting your enrollment destroys the encryption key as well (crypto-shredding).

Automated guard tests scan the source tree for networking, disk writes of image data, console
output and data-carrying XPC methods. Details: [docs/security.md](docs/security.md).

## Known limitations

- **A missing or damaged plugin is treated by macOS as a pass** (confirmed in a VM).
  `FaceIDBroker` therefore checks the plugin every 5 seconds and restores the original unlock
  rule as soon as a problem is found (measured: 0.2 s when the bundle is removed, 2 s when the
  binary is corrupted). If the broker is not running either, nothing restores the rule —
  **never delete FaceID files by hand; always use `uninstall.sh`**.
- After a face unlock, macOS may ask for your Apple Account password in System Settings,
  because no password was entered.
- 2D camera spoofing tests are incomplete: a photo on a phone screen is rejected ✅; printed
  photos and video replay have not been tested yet.
- FaceID cannot replace Touch ID, unlock FileVault at boot, or unlock the login keychain.

## Documentation

| Document | Contents |
|---|---|
| [docs/security.md](docs/security.md) | Threat model, data flow and hardening measures |
| [docs/local-signing.md](docs/local-signing.md) | Creating a free local signing certificate and signing builds |
| [docs/plugin-vm-test.md](docs/plugin-vm-test.md) | Lock-screen plugin test plan and recorded VM results |
| [docs/main-mac-test.md](docs/main-mac-test.md) | Test plan for a physical Mac |
| [Scripts/recovery.md](Scripts/recovery.md) | How to recover if you cannot unlock |
| [Models/README.md](Models/README.md) | Embedding model source, conversion and license |
| [CLAUDE.md](CLAUDE.md) | Engineering guidelines and security rules for contributors |

Some documents are currently written in Thai.

## Third-party components

- **SFace** face recognition model — Apache License 2.0. See [Models/NOTICE](Models/NOTICE).
