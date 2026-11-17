# EZAIStatus

*[Version française](README.fr.md)*

A tiny macOS menu bar app that shows how many AI coding conversations on this Mac are **running**, **waiting for you**,
or **finished** with a response you haven't read yet. Click it to see the titles grouped by state (waiting first), with the
project and the active subagents or background commands. Click a title to open that conversation directly.

Supported apps: **Codex** (ChatGPT app) and **Claude Code** (Claude desktop app). Subagents are shown under their
conversation but never counted.

## Principles

- **Local only.** Reads the apps' own files read-only. No account, no server, no network access.
- **Light.** File-system events (FSEvents) instead of polling; about 1 % of one core and 20–30 MB of memory.
- **Honest.** A source it can't read is flagged as unreadable, never shown as zero.
- **Quiet by default.** Past conversations are ignored at first launch. Notifications and launch at login are off until you
  turn them on.
- **French and English** interface, selectable in Settings.

The only file it writes outside its own folder is the optional Claude Code hook (off by default), which detects tool
permission requests. When enabled in Settings it adds an entry to `~/.claude/settings.json`, after making a backup.

None of these apps publishes an API for these states, so EZAIStatus relies on their internal files, which may change with
any update. Technical notes, in French: [FAISABILITE.md](FAISABILITE.md).

## Requirements

macOS 14 or later, Apple Silicon or Intel. Distributed outside the Mac App Store: its sandbox forbids reading other apps' files.

## Build

```bash
swift test                       # core tests
scripts/build-app.sh             # build/EZAIStatus.app, ad hoc signature for this Mac
scripts/build-app.sh --release   # Developer ID signature + hardened runtime
scripts/notarize-xcode.sh        # notarization with the account signed in to Xcode, builds build/EZAIStatus.zip
scripts/publish-update.sh        # Sparkle update (zip + signed appcast), once release.env is filled in
swift scripts/make-icon.swift    # regenerates Resources/AppIcon.icns
```

Headless diagnostics: `swift run ezaistatus-probe` (or `--all`) prints what each connector sees.

Automatic updates use [Sparkle](https://sparkle-project.org). They stay disabled until `release.env` holds the appcast URL
and the public EdDSA key.

## License

[MIT](LICENSE)
