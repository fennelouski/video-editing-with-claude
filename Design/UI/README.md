# Synthetic UI verification

Run from the repository root:

```sh
Design/UI/scripts/capture_ui.sh Design/UI/previews/round-1
```

The script builds a dedicated verification CLI in `/tmp`, not the Clauto app. It
uses the outer execution sandbox and disables only the compiler's nested plugin
sandbox, which cannot start inside that host sandbox. It does not change the live
`dist` app, launch a foreground window, load private projects or media, run engine
commands, invoke Claude, check update feeds, or install fonts.

Its temporary project contains synthetic records and explicitly labelled file
placeholders, including a deliberately unavailable saved preview for recovery-state checks. Existing Work Sans is registered only for this process. Native
`NSHostingView` offscreen renders are written as PNGs with an accessibility/control
report. A role or action that cannot be inspected is recorded as unavailable.

These captures verify composition, font loading, labels, native text surfaces,
and native text editing. Offscreen accessibility actions are unavailable in this host; no press or adjustable-action pass is claimed. The host also denied synthetic video encoding, so saved-cut captures use metadata-only fixtures and valid video playback remains unverified. They do not verify
physical pointer hover, drag delivery, foreground keyboard traversal, VoiceOver
speech, or AVPlayer hardware video layers. Those checks require a later synthetic
live-app review authorized by Nathan.

The isolated Xcode build goes to `.artifacts/DesignDerivedData`. It uses the
already cached Sparkle dependency and disables package updates and automatic
resolution. No production bundle or user launch is part of this workflow.
