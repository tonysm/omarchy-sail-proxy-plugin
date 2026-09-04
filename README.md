# Sail Proxy — an Omarchy bar plugin

[`sail-proxy`](https://github.com/tonysm/sail-proxy) puts local Laravel Sail apps behind a
kamal-proxy container, so each is reachable at `http://<app>.localhost`. Finding out what's
registered, whether the proxy is up, or which directory a hostname belongs to otherwise means
opening a terminal and reading a table.

This is that table in the status bar: proxy on/off at a glance, and a popup listing every
registered domain with its project directory and whether its container is running.

```
● livewire-starter-kit.localhost              󰉋  󰆍  󰆏  󰩹
  ~/Code/livewire-starter-kit · running
```

Clicking a row opens the site in a focused browser window. The four buttons open the project's
directory in your file manager, open it in a terminal, copy its path to the clipboard, and
unregister it — the last arming first, so it takes two clicks.

The dot is the theme's accent when the container is running, and muted when it is gone. It
deliberately does *not* use `urgent` for the gone state: a theme is free to map that to anything —
this machine's defines `red = #50f872`, a green — and an alert color that reads as healthy would
put the loudest mark on the broken row. Brightness carries the state instead, which holds up on
any palette.

## Install

The plugin is a git repo, cloned into place:

```bash
omarchy plugin add https://github.com/tonysm/omarchy-sail-proxy-plugin.git --enable --yes
```

It needs the `sail-proxy` CLI, which [mise](https://mise.jdx.dev) installs and updates:

```bash
omarchy-mise-install github:tonysm/sail-proxy sail-proxy && sail-proxy --version
```

If the CLI is missing or too old, the popup says so and offers a button that runs exactly that
command in a floating terminal — so there is nothing to install by hand.

**Updating the CLI** is `mise up github:tonysm/sail-proxy`. The plugin deliberately does no version
polling: `~/.local/share/mise/shims` precedes `~/.local/bin` on the shell's PATH, so mise's own
shim is what actually runs, and having the widget re-resolve it on every poll would mean a network
call every 30 seconds.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Custom sail-proxy path | *(empty)* | Use this binary instead of the one on PATH. For developing `sail-proxy` itself. |
| Refresh interval | 30 s | How often the bar icon's state is refreshed. |
| Refresh while open | 5 s | Faster polling while the popup is open. |
| Folder button opens | Files | `files` (`xdg-open`), `editor`, or `terminal`. |

## Keyboard

| Key | Action |
|---|---|
| `↑` `↓` / `k` `j` | Move between rows |
| `←` `→` / `h` `l` | Move across row → folder → terminal → copy → unregister |
| `Enter` | Activate whatever is focused |
| `o` | Open the selected row's folder |
| `t` | Open the selected row's directory in a terminal |
| `c` | Copy the selected row's path to the clipboard |
| `x` `x` | Arm, then confirm, an unregister |
| `r` | Refresh |
| `s` | Start/stop the proxy |
| `Esc` | Disarm an armed unregister, then close |

Copying uses `wl-copy` (wl-clipboard), the same as the shell's own network and Tailscale panels.

## What the widget can know

Everything comes from `sail-proxy status --json`. That command **exits 0 even when the proxy is
off**, so state is read from the parsed `active` field and never from an exit code — the one thing
the exit code does say is `127`, meaning the CLI is not on PATH.

`installed` is read straight from the JSON rather than inferred from `active`, so stopping the
container shows *stopped*, not *not installed*.

Container liveness comes from `exists`, which is `docker inspect` succeeding — **true for a stopped
container too**, so a stopped-but-present container reads as `running`. `state` can't help: it is
kamal-proxy's service pause state and outlives the container. `Model.containerRunning()` prefers a
`running` key if one ever appears in the JSON, so the plugin sharpens itself with no UI change.

The plugin never calls `uninstall` — it destroys the volume and every registration.

## Development

For the inner loop:

```bash
rsync -a --delete --exclude .git ~/Code/omarchy-sail-proxy-plugin/ ~/.config/omarchy/plugins/tonysm.sail-proxy/
omarchy plugin validate ~/Code/omarchy-sail-proxy-plugin   # must exit 0
omarchy-restart-shell
```

Editing files under `~/.config/omarchy/plugins/` is documented as hot-reloading on save, but an
already-instantiated bar widget keeps its old QML: neither `rsync` (which preserves mtimes) nor
`omarchy-shell shell rescanPlugins` picked up edits here. `omarchy-restart-shell` is the reliable
step, and it restarts only the bar and panels — not Hyprland, so no windows are disturbed.

`Model.js` is pure JS with `module.exports` at the bottom, so it loads in node directly:

```bash
node -e 'const M = require("./Model.js"); console.log(M.bodyState(false, true, true, 2))'
```

### Reaching the states your machine isn't in

Point **Custom sail-proxy path** at a stub and every body state is reachable without docker
wrangling, and without `sail-proxy uninstall`:

```bash
cat > /tmp/fake-sail-proxy <<'EOF'
#!/bin/bash
[ -f "$HOME/.sail-proxy-fixture-exit" ] && exit "$(cat "$HOME/.sail-proxy-fixture-exit")"
[ "$1" = "status" ] && exec cat "$HOME/.sail-proxy-fixture.json"
exit 0
EOF
chmod +x /tmp/fake-sail-proxy
```

Then vary the fixture:

| Fixture | Body |
|---|---|
| `{"installed":false,"active":false,"projects":[]}` | `not-installed` |
| `{"installed":true,"active":false,"projects":[]}` | `stopped` |
| `{"installed":true,"active":true,"projects":[]}` | `empty` |
| the same JSON with `installed` deleted | `setup` — the CLI is too old |
| `echo 127 > ~/.sail-proxy-fixture-exit` | `setup` — the CLI is missing |

The widget's current state is readable over IPC, which is how the above is checked:

```bash
omarchy-shell tonysm.sail-proxy status
```

## License

MIT. Parts of `Model.js` are copied or adapted from the
[HEY Omarchy plugin](https://github.com/basecamp/omarchy-hey-plugin) (MIT,
Copyright (c) 2026 37signals LLC) — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
