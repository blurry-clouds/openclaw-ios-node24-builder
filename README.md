# OpenClaw-compatible Node 24 iOS builder

This public build-only repository produces an experimental arm64 iOS 15
Node.js 24.15 runtime bundle using a standard GitHub-hosted macOS runner.

It contains only the reproducible build workflow, the audited NodeMobile
forward-port script, the minimal launcher, and artifact inspection checks.
It contains no device addresses, credentials, signing identities, OpenClaw
configuration, deployment automation, or private project history.

## Build

Run **Build OpenClaw-compatible Node 24 iOS** from the Actions tab. The
workflow uploads a seven-day artifact containing:

- `node-ios`
- `Frameworks/NodeMobile.framework`
- `BUILD-REPORT.txt`

The artifact is ad-hoc signed for inspection. A jailbroken test device may
require device-local pseudo-signing with its own appropriate entitlements.

## Scope and limitations

This is an experiment for an iPhone 7 Plus-class arm64 device on iOS 15. It
does not bypass Activation Lock, install a jailbreak, provide an App Store
application, or include OpenClaw itself. NodeMobile disables V8 WebAssembly,
and iOS-incompatible native Node add-ons remain unsupported. The build enables
full ICU because current OpenClaw bundles require Unicode-property regular
expressions that the upstream mobile wrapper's `--with-intl=none` build cannot
parse.
