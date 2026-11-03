# Changelog

## 1.2.1

First release from this repository. The plugin had lived only in
`~/.config/omarchy/plugins`, with its two helper scripts in `~/.local/bin` and
the watchdog enabled as a user service.

- `bin/bt-call` and `bin/bt-call-daemon` now ship inside the plugin, and the
  panel resolves them relative to its own directory. `omarchy plugin add` is
  the complete installation; no script goes into `~/.local/bin`.
- The watchdog is started by the panel and killed with it, instead of
  `bt-call-watch.service`. It holds a lock so a shell reload cannot end up
  with two of them, and it exits if its parent shell goes away.
- The watchdog line in the panel reports the running process instead of a
  systemd unit's state.
- The missing-quirk warning named `bt-audio-check`, which is not part of this
  plugin; it now says to rebuild `btbcm-apple-quirk` and reboot.
- README, license and preview for the marketplace, with the scripts' comments
  in English.

## 1.2.0

- Follow whichever headphones or headset is connected instead of pinning the
  AirPods. The call/music trouble comes from the controller, not from one
  pair, so every pair gets the same panel.
- Playback codec rows come from what the connected pair actually negotiated,
  and the choice is restored after a call.

## 1.1.0

- Playback codec picker for A2DP (LDAC, aptX HD, SBC-XQ, AAC, aptX, SBC).
- The panel reports whether `btbcm_apple_quirk` is loaded, and offers CVSD as
  the escape hatch when mSBC would be silent.

## 1.0.0

- Call/music mode, call codec selection, and the call watchdog.
