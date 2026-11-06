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
- Installed GitHub CLI and Node under `D:\Tools`; portable Bun/Go setup is still being repaired.

## Current

- Baseline upstream-source IPA build: <https://github.com/EricHe03/solo-agent/actions/runs/42226898947> (in progress; Xcode/Go/Node/Bun setup, dependencies, and physical-iOS LibSwipt succeeded; React Native setup is still running).
- Committing the first integrated implementation locally, then pushing after the baseline finishes so its run is not cancelled by workflow concurrency.
- Checking the new Go and Swift code through the real macOS build loop.

## Remaining

- Obtain a successful baseline IPA, then build and debug the integrated agent IPA.
- Add concise installation, LocalDevVPN/sing-box pairing, provider, background-limit, and SideStore instructions.
- Run physical-device Wi-Fi Settings and Safari Search tests; neither has been performed.

## Known Issues / Verification Limits

- No iPhone is attached to this Windows environment; all device-control behavior remains unverified.
- New Go/Swift sources have not compiled yet. `libswipt/agent.go` still needs formatting and build validation.
- The portable tool installer timed out and produced a partial Bun archive; its retry is running. Tools previously installed by winget under system locations still need relocation cleanup.
- SideStore signing/provisioning and required App Group behavior are unverified. An unsigned IPA is not directly installable.

## Technical Decisions

- Working brand: **Solo Agent**; preserve source folder/module names for upstream merge compatibility and use original branding only.
- Call `LibSwipt` in process through typed JSON tool calls; do not expose AI-generated JavaScript and do not require MCP/HTTP or an external control server.
- Use OpenAI-compatible Chat Completions first, HTTPS endpoints, user API keys in Keychain, and image attachments only when screenshot data is requested.
- Reuse Swipt pairing, LocalDevVPN/sing-box loopback, Developer Disk Images, Accessibility selectors, and background audio/location support. Do not claim unrestricted background execution.
- Treat all screen content as untrusted data; require confirmation for model-flagged consequential actions and detected secure/sensitive controls.

## Git / Actions

- Upstream baseline SHA: `a9e7c64` (`Add basic vphone support`).
- Latest commit: `10a1aa5` (`ci: build unsigned iOS IPA without release publishing`).
- Actions: baseline run `42226898947`, queued. No IPA artifact has been verified yet.
