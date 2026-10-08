# Workspace 3D

3D workspace switching for [Omarchy](https://omarchy.org): page-flip, flythrough
and coverflow transitions rendered as a transparent overlay on top of Hyprland.

Switches stay instant. The animation is purely visual: Hyprland moves you to the
new workspace immediately, and a fullscreen overlay plays the transition over it,
so nothing in your session waits on the effect.

## How it works

- A rolling cache of screenshots (`~/.cache/omarchy-workspace3d/`) is kept fresh
  by `grim`, captured shortly after each switch while the shell is idle.
- On a workspace switch, an always-mapped overlay window per monitor shows the
  cached image of the outgoing workspace and animates it with a `Matrix4x4`
  projection (real perspective divide), while the new workspace is already live
  underneath.
- Because the next workspace is revealed directly from the compositor, the
  effect works on every switch path (keybinds, scroll, dispatch, workspace
  rules) without hooking or delaying anything.

## Install

```sh
omarchy plugin add https://github.com/ChazPounder78/omarchy-workspace3d --enable --yes
```

## Remove

```sh
omarchy plugin remove chaz.workspace3d --yes
```

Removing the plugin leaves no changes behind: it never edits Hyprland, Quickshell
or Omarchy configuration, and it owns only its cache directory (safe to delete at
any time):

```sh
rm -rf ~/.cache/omarchy-workspace3d
```

## Requirements

- Omarchy shell (Quickshell) and Hyprland - standard Omarchy installs have both.
- `grim` for captures (installed by default on Omarchy).

## Configuration

Settings live in `~/.config/omarchy/workspace3d.json` (created with defaults on
first run, watched for changes):

```json
{
  "enabled": true,
  "style": "flip",
  "duration": 350,
  "easing": "outCubic"
}
```

| Key        | Values                                                                  |
| ---------- | ----------------------------------------------------------------------- |
| `enabled`  | `true` / `false`                                                        |
| `style`    | `flip`, `flythrough`, `coverflow`                                       |
| `duration` | animation length in ms, clamped to `100` - `5000`                       |
| `easing`   | any Qt easing name in camelCase, e.g. `outCubic`, `inOutBack`, `linear` |

## IPC

```sh
omarchy-shell workspace3d status          # read all settings and live state
omarchy-shell workspace3d style coverflow  # set style (flip|flythrough|coverflow)
omarchy-shell workspace3d duration 400     # set duration in ms
omarchy-shell workspace3d easing outBack   # set easing
omarchy-shell workspace3d enable off       # toggle the effect
omarchy-shell workspace3d preview          # play a transition now
omarchy-shell workspace3d refresh          # recapture the screenshot cache
```

Setters return the value they applied (or `invalid`), `status` returns JSON -
there are no argument-less getters, use `status` to read.

## Notes

- Screenshots never leave your machine; captures are made with `grim` of your
  own outputs and stored only in the local cache.
- The overlay is click-through (empty input region), transparent to keyboard
  focus, and sits on the Hyprland overlay layer - it never intercepts input.
- No Hyprland config, layer rules or keybinds are modified.

## License

MIT
