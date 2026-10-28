# Backlog

Ideas parked for later.

- **Copy cookies from Chrome.** Requested 2026-10; parked ("backlog for now").
  Open question: copy them to what (a cookies.txt for scripts, Claude's
  Playwright runs, or an in-app browser). Reading them needs Keychain access
  to "Chrome Safe Storage".
- **Developer ID signing for releases.** Requested 2026-10. Releases are
  signed for this Mac only, so other Macs block them until allowed in
  Privacy & Security. Needs an Apple Developer account ($99/yr), then
  `DEVELOPER_ID` and `NOTARY_PROFILE` set for `release.sh`.
  - Two signing tiers: local builds use whatever identity `sign-id.sh`
    finds; releases want a Developer ID plus notarization.
  - Hardened runtime (`--options runtime`) is on everywhere; only the
    release path adds `--timestamp` and notarization.
  - `--deep` is used throughout. Apple now recommends signing nested
    components one by one; check it once the CEF helper apps are bundled.
