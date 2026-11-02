# Swipt

The universal iOS automation platform.

## Requirements

* iOS 27; no jailbreak or TrollStore required (though sideloading is obviously necessary)

## Architecture

* Swipt SDK: A TypeScript SDK built upon CoreDevice, Accessibility services, and other developer services.
* Swipt API (MCP-compatible): Allows you to run a JS REPL based on the Swipt SDK directly, enabling you to control an iPhone or iPad, manage and debug Swiplets.
* Swipt CLI: A client for the Swipt API that offers a more comprehensive set of features than MCP.
* Swiplet: Apps that run within Swipt, built using the Swipt SDK and SwiftUI.

## Installation

### App

Sideload the app by adding the source to SideStore or AltStore:

```
https://github.com/swipt-automation/swipt/releases/latest/download/altstore.json
```

Or download [Swipt.ipa](https://github.com/swipt-automation/swipt/releases/latest/download/Swipt.ipa) and sideload it.

### CLI

```shell
npm install -g @swipt/cli
```
