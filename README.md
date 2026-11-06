# Solo Agent

Solo Agent is a standalone, on-device AI agent for iOS 27. It combines a SwiftUI chat interface and an OpenAI-compatible observe–reason–act loop with Swipt’s CoreDevice, Accessibility, HID, pairing, and loopback automation engine.

It is an independent GPLv3 derivative of [Swipt](https://github.com/swipt-automation/swipt), not an official Swipt product. Source and upstream notices are available in this repository and in `LICENSE`.

## Status

- **Verified build:** [Actions run 42232721394](https://github.com/EricHe03/solo-agent/actions/runs/42232721394) produced an unsigned physical-iOS ARM64 `SoloAgent.ipa` (version 0.1.0 build 5, source `374ee50`).
- **Device verification:** No physical-device tests have been completed from the Windows development environment. Compilation does not prove that pairing, automation, or the example tasks work on an iPhone.
- **Requirements:** iPhone/iPad running iOS 27, Developer Mode, a compatible loopback VPN, and an OpenAI-compatible API account/key.

## Implemented Agent

- Natural-language chat, progress/current-action display, execution log, cancellation, completion/failure states.
- Configurable HTTPS API base URL, model, API key, maximum steps, action timeout, and observation retries.
- Keychain storage for the API key; no credentials are committed to the repository.
- Structured Chat Completions tool calling and optional screenshot image attachments.
- Typed in-process `LibSwipt` calls; no external control server, MCP loop, or AI-generated JavaScript.
- Device information, foreground app, accessibility tree, screenshot, launch, semantic tap, coordinate tap, swipe, verified text entry/Return, Home, accessibility Escape as a best-effort Back equivalent, and bounded screen waits.
- Post-action observation, screen-change fingerprints, retry/repetition limits, and confirmation for flagged consequential or detected secure/sensitive actions.
- Existing Swipt pairing, automatic unlock, and audio/location keep-active support.

iOS has no universal Back button. `press_back` attempts the foreground app’s Accessibility Escape action and reports failure rather than pretending a navigation occurred.

## Build with GitHub Actions

The workflow uses the GitHub-hosted `xcode-27` Arm64 image and does not require a local Mac.

1. Open [Actions](../../actions/workflows/build.yml).
2. Run **Build iOS IPA**, or push to `main`.
3. After a successful run, download the **Solo-Agent-iOS-IPA** artifact.
4. Extract `SoloAgent.ipa`. The artifact also contains dSYMs, metadata, and the icon.

Do not compile the SwiftUI/iOS targets on Windows. Local Go formatting and non-Xcode checks are fine; all Xcode-dependent compilation belongs on the macOS runner.

## Install with SideStore

An unsigned IPA must be signed during installation.

1. Install and configure [SideStore](https://docs.sidestore.io/docs/installation/install) using its current official instructions. A computer is needed for initial SideStore setup, but not for normal agent operation.
2. On the iPhone, trust the developer profile and enable **Settings › Privacy & Security › Developer Mode**. Restart when iOS requests it.
3. Connect LocalDevVPN for SideStore installation/refresh, open **SideStore › My Apps**, tap **+**, and choose `SoloAgent.ipa`.
4. Sign with your Apple Account. If SideStore reports a provisioning error, use a compatible signing profile rather than stripping required app capabilities.
5. Refresh the app before a free provisioning profile expires (normally seven days). Keep the original IPA available.

**Signing is not yet device-verified.** The iOS target does not use the macOS-only App Group entitlement; its inherited empty `AppGroupIdentifier` plist key is unused, matching the upstream iOS IPA. SideStore must still preserve embedded frameworks, local-network/background declarations, and the bundle ID. Free provisioning normally requires periodic refresh. No unsupported entitlement bypass is claimed.

## Local Pairing and Loopback VPN

1. Install [LocalDevVPN](https://apps.apple.com/app/id6755608044) (recommended) or sing-box. Open Solo Agent and follow **Device Setup**.
2. In iOS Settings, open **Privacy & Security › Developer Mode**, choose this iPhone under the pairing list, and enter the code displayed by Solo Agent.
3. Allow Local Network permission when prompted. Pairing records stay in the app container and must never be committed.
4. Connect LocalDevVPN. If using sing-box, import the example `LocalDevVPN.bpf` profile from the in-app setup screen.
5. Return to Solo Agent and wait for **Pairing: Paired**, **Loopback VPN: Detected**, and **Developer connection: Connected**.
6. Configure Automatic Unlock only if you accept its security implications; otherwise unlock the iPhone manually before tasks.

Only one iOS packet-tunnel VPN can normally be active. Shadowrocket, privacy VPNs, DNS blockers, or another packet tunnel can disconnect the required loopback VPN. Disable the conflicting tunnel while using Solo Agent. A separate VPN app is currently required because the standalone app does not include its own packet-tunnel extension.

## Configure the AI Provider

1. Open **Solo Agent › Settings › AI Provider**.
2. Enter an OpenAI-compatible base URL, such as:
   - OpenAI: `https://api.openai.com/v1`
   - OpenRouter: `https://openrouter.ai/api/v1`
3. Enter a model identifier that supports tool/function calling and, if screenshots are needed, multimodal image input.
4. Enter your API key and tap **Save Key & Test Connection**.
5. Adjust step, timeout, and retry limits if needed.

A full `.../chat/completions` URL is also accepted. Only HTTPS endpoints are accepted. ChatGPT, Claude, or Gemini consumer subscriptions do not automatically provide third-party API credentials. Streaming is not enabled in the MVP.

## Physical Acceptance Tests

Complete setup and use an unlocked iPhone. These tests are instructions, not recorded results:

1. **Wi-Fi Settings:** send `Open Settings and navigate to the Wi-Fi page.` Verify the agent launches `com.apple.Preferences`, taps the semantic Wi-Fi element, observes the Wi-Fi screen, and calls `finish_task`.
2. **Safari Search:** send `Open Safari and search for OpenAI.` Verify the agent launches `com.apple.mobilesafari`, enters `OpenAI` in the address/search field, submits with Return, observes search results, and calls `finish_task`.

Record model/provider, iOS build, IPA commit, execution log, and any failed action when reporting results. Do not mark either test passed based only on source review or an Actions build.

## Background Limits

Solo Agent activates Swipt’s existing audio or location keep-active mode during a task. iOS may still suspend or terminate the app when resources change, permissions are revoked, another VPN/audio session interferes, or the system reclaims the process. Unrestricted background execution is not claimed.

## Development

- `upstream`: `https://github.com/swipt-automation/swipt.git`
- `origin`: `https://github.com/EricHe03/solo-agent.git`
- Read `PROGRESS.md` before making changes and update it at milestones.
- The optional `dev/install-windows-tools.ps1` installs portable GitHub CLI, Node, Bun, and Go under `D:\Tools`.
- Preserve `LICENSE`, upstream notices, and source availability. Do not use branding that implies association with Swipt.

Never commit API keys, pairing records, signing identities, provisioning profiles, or personal secrets.
