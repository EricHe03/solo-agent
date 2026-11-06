# Solo Agent Progress

_Last updated: 2026-11-06_

## Completed

- Inspected the real Swipt CoreDevice, Accessibility, HID, pairing, loopback VPN, screenshot, and background implementations.
- Authenticated GitHub as `EricHe03`; created <https://github.com/EricHe03/solo-agent> and retained `swipt-automation/swipt` as the `upstream` remote.
- Replaced fork publishing jobs with a minimal unsigned physical-iOS ARM64 IPA workflow on the GitHub-hosted `xcode-27` runner.
- Added a cancellable, strict-JSON `LibSwiptAgentToolCall` bridge using real Swipt operations (uncommitted).
- Added typed OpenAI-compatible Chat Completions models/client, tool schemas, Keychain API-key storage, and the initial agent controller.
- Added SwiftUI chat/history, progress, execution logs, Stop, sensitive-action alerts, provider testing, agent limits, and device setup/status screens.
- Added original Solo Agent branding, bundle ID `io.github.eriche03.soloagent`, icon, `SoloAgent.app`/`SoloAgent.ipa` packaging, installation documentation, and progress instructions.
- Installed and verified GitHub CLI 2.103.3, Node 26.13.0, Bun 1.4.4, and Go 1.27.3 under `D:\Tools`; registered their user `PATH` entries.
- Local check passed: `node dev/check-agent-tools.cjs` validated all 13 required tool schemas; the same check now runs in CI.

## Current

- Baseline upstream-source IPA build passed: <https://github.com/EricHe03/solo-agent/actions/runs/42226898947> in 18m1s.
- Downloaded baseline artifact `Solo-Agent-iOS-IPA`: real `Swipt.ipa` (43,601,500 bytes; SHA-256 `5F41E6F093EE99380A765AC6279B53D829BC259D83A0569D7270E7BEAC24C9AB`), dSYMs, icon, and metadata for commit `10a1aa5`, version 0.1.0 build 1.
- Integrated run `42229591276` failed only at the Swift archive after Go/framework setup succeeded. Actual errors were invalid `LibSolo Agent` identifiers in `PairingSession.swift` caused by over-broad rebranding; restored all five to `LibSwipt` in `7cdc811`.
- Run `42231503204` advanced to the agent Swift sources but failed on two `Section` title-plus-footer builder type-inference errors (`AgentSettingsView.swift:14`, `AgentDeviceView.swift:47`). Converted both to explicit header/footer builders.
- Rebuild after the SwiftUI section fix and inspect any remaining errors.

## Remaining

- Build and debug the integrated agent IPA, then download and inspect `SoloAgent.ipa`.
- Add concise installation, LocalDevVPN/sing-box pairing, provider, background-limit, and SideStore instructions.
- Run physical-device Wi-Fi Settings and Safari Search tests; neither has been performed.

## Known Issues / Verification Limits

- No iPhone is attached to this Windows environment; all device-control behavior remains unverified.
- New Go/Swift sources have not compiled yet. `libswipt/agent.go` still needs formatting and build validation.
- Portable tool setup recovered from partial downloads. Portable Bun was removed from its old user location; winget removal of duplicate GitHub CLI, Node, and Go system installations failed with installer code `1603`, but the verified `D:\Tools` copies are independent.
- SideStore signing/provisioning and required App Group behavior are unverified. An unsigned IPA is not directly installable.

## Technical Decisions

- Working brand: **Solo Agent**; preserve source folder/module names for upstream merge compatibility and use original branding only.
- Call `LibSwipt` in process through typed JSON tool calls; do not expose AI-generated JavaScript and do not require MCP/HTTP or an external control server.
- Use OpenAI-compatible Chat Completions first, HTTPS endpoints, user API keys in Keychain, and image attachments only when screenshot data is requested.
- Reuse Swipt pairing, LocalDevVPN/sing-box loopback, Developer Disk Images, Accessibility selectors, and background audio/location support. Do not claim unrestricted background execution.
- Treat all screen content as untrusted data; require confirmation for model-flagged consequential actions and detected secure/sensitive controls.

## Git / Actions

- Upstream baseline SHA: `a9e7c64` (`Add basic vphone support`).
- Latest pushed commit before this SwiftUI fix: `c7a1cde`; previous fixes: `7cdc811`, `0090752`.
- Integrated implementation commits: `67390d6`, `0090752`, `97db01a`; baseline workflow: `10a1aa5`.
- Actions: baseline `42226898947` succeeded and was downloaded. Integrated runs `42229591276` (LibSwipt naming errors) and `42231503204` (SwiftUI Section builder errors) failed at archive; fixes are committed locally. No integrated IPA yet.
