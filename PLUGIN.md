# Gliff bar plugin (nixfred.gliff)

This fork of [omacom/gliff](https://github.com/omacom/gliff) adds one thing on top of upstream: an Omarchy bar plugin. It only adds files at the repo root (`manifest.json`, `BarWidget.qml`, `GliffPanel.qml`, this file) and never edits upstream files, so upstream merges cleanly. Everything else is gliff itself; see `README.md`.

An Omarchy bar button for [gliff](https://github.com/omacom/gliff), the remote desktop for Hyprland over ssh.

Click the monitor icon, click a machine, and its desktop opens in a gliff window.

- **Used before**: every machine gliff has connected to (read from `~/.config/gliff/config.toml`).
- **Omarchy on your tailnet**: online Linux nodes from `tailscale status` that answer a read-only
  `ssh` check for `/usr/share/omarchy`. The check uses `BatchMode`, so a machine you cannot reach by
  key is left out instead of prompting. Results are kept until the shell restarts.
- **Mirror screen / Private screen**: mirror shows the remote's focused screen; private adds `--headless`.
- Type to filter. Enter opens the top match, or whatever you typed (`user@host`) when nothing matches.
  Up/Down moves, Esc closes.
- **Open Gliff** opens the bare app.

gliff must be installed on both ends (`omarchy pkg add gliff`). IPC: `omarchy-shell nixfred.gliff open|close|toggle|status|connect <user@host>`.

## Install

```
omarchy plugin add https://github.com/nixfred/gliff --enable
```

## Staying current with upstream

```
git fetch origin && git merge origin/main && git push fork main
```

(`origin` is omacom/gliff, fetch only; `fork` is nixfred/gliff.)

## Developing

Edit in a checkout, then copy into `~/.config/omarchy/plugins/nixfred.gliff` in one step, because
file-by-file edits in the live folder reload the shell on every save. A changed `BarWidget.qml` needs
`omarchy restart shell`; hot reload alone does not always pick it up.
