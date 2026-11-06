# Solo Agent Progress

_Last updated: 2026-11-06_

## Completed

- Created <https://github.com/EricHe03/solo-agent> from Swipt `a9e7c64`; retained upstream as a separate remote and preserved GPLv3 notices.
- Implemented original Solo Agent branding, icon, bundle ID `io.github.eriche03.soloagent`, `SoloAgent.app`, and unsigned `SoloAgent.ipa` packaging on the `xcode-27` runner.
- Added the in-process, cancellable, strict-JSON `LibSwiptAgentToolCall` bridge for all 13 required tools; no external server or AI-generated JavaScript.
- Added OpenAI-compatible Chat Completions, multimodal screenshots, HTTPS configuration, Keychain API keys, connectivity testing, and configurable step/timeout/retry limits.
- Added observe–reason–act orchestration, post-action observation, screen-change fingerprints, cancellation, repetition limits, sensitive-action confirmation, and untrusted-screen-data handling.
- Added SwiftUI chat/history, progress/current action, expandable execution logs, Stop, completion/failure states, provider settings, and device setup/status screens.
- Reused Swipt pairing, LocalDevVPN/sing-box loopback, Developer Disk Image, automatic unlock, and audio/location keep-active support.
- Added installation, pairing, provider, background-limit, physical-test, and development instructions plus `AGENTS.md`/`NOTICE.md`.
- Installed and verified GitHub CLI 2.103.3, Node 26.13.0, Bun 1.4.4, and Go 1.27.3 under `D:\Tools`.
- Local and CI schema checks passed for all 13 tool definitions.

## Verified Builds / Artifact Checks

- Baseline run <https://github.com/EricHe03/solo-agent/actions/runs/42226898947> succeeded in 18m1s. Downloaded `Swipt.ipa` (43,601,500 bytes; SHA-256 `5F41E6F093EE99380A765AC6279B53D829BC259D83A0569D7270E7BEAC24C9AB`).
- Integrated run <https://github.com/EricHe03/solo-agent/actions/runs/42232721394> **succeeded** in 8m3s for `374ee50`, version 0.1.0 build 5.
- Downloaded integrated `SoloAgent.ipa` (44,203,156 bytes; SHA-256 `363B78918034E9C15ECC9601C0829D0739B3C1B8A3B6C78AF705F680DFD7678F`) from artifact `13509813196`.
- IPA inspection found 1,004 entries, zero `_CodeSignature` entries, `Payload/SoloAgent.app`, a 36,035,536-byte `SoloAgent` executable, Developer Disk Image, `main.jsbundle`, embedded frameworks, and embedded agent tool strings.
- Plist inspection confirmed display name `Solo Agent`, bundle ID `io.github.eriche03.soloagent`, arm64/iPhoneOS, iOS 27.2 SDK/Xcode 27.2, local-network and background declarations. LibSwipt is statically linked rather than a separate embedded framework.

## Current

- Final documentation/status update only. No compilation or packaging task is active.

## Remaining

- Install/sign through SideStore and test pairing on the physical iPhone 15 Pro.
- Run the Wi-Fi Settings and Safari Search acceptance tests with a real API key; neither has been performed.
- After device verification, improve reliability/onboarding as needed. Streaming responses and additional provider-specific adapters are optional follow-ups.

## Known Issues / Verification Limits

- No iPhone or AI API credential is attached to this Windows environment. Device control, pairing, VPN behavior, API connectivity, and both acceptance tests remain unverified; compilation is not a device test.
- SideStore signing/installation is unverified. The unsigned IPA cannot be installed without signing. The inherited empty `AppGroupIdentifier` is unused on iOS and matches upstream; App Group storage/entitlement is macOS-only.
- `press_back` is only a best-effort Accessibility Escape action because iOS has no universal Back button. A separate packet-tunnel VPN app remains necessary; VPN conflicts and iOS suspension can interrupt automation.
- Duplicate system installations of GitHub CLI, Node, and Go could not be removed with winget (`1603`); independent portable copies work under `D:\Tools`.

## Technical Decisions

- Preserve Swipt source/module/scheme names for merge compatibility while using Solo Agent product branding. Do not imply official association.
- Prefer semantic Accessibility refs over coordinates. Treat screen content as untrusted data and redact typed text from action logs.
- Reuse existing audio/location background support without claiming unrestricted execution. Only one packet-tunnel VPN should be active.

## Git / Build Errors Resolved

- Latest build/source commit: `374ee50` (`fix: use explicit SwiftUI section builders`). Earlier implementation commits: `67390d6`, `0090752`, `97db01a`, `7cdc811`.
- Integrated run `42229591276` failed on accidental `LibSolo Agent` identifiers; fixed in `7cdc811`.
- Run `42231503204` failed on two SwiftUI Section title/footer builder errors; fixed in `374ee50`.
- Final run `42232721394` succeeded and its artifact was downloaded and inspected.
