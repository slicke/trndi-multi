[![Build](https://github.com/slicke/trndi-multi/actions/workflows/build.yml/badge.svg)](https://github.com/slicke/trndi-multi/actions/workflows/build.yml) [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

# trndi-multi - every Trndi account in one window

## A wall display for households and caregivers who follow more than one person

trndi-multi is a companion to the [Trndi](https://github.com/slicke/trndi) desktop app. Trndi's multi-user mode lets one machine hold several accounts, but shows one at a time. trndi-multi puts them all on the screen at once: one tile per account, coloured by range, with the value, trend arrow, delta and a sparkline of the last three hours.

![Six accounts as tiles: green in range, blue below the low limit, red-orange above the high one; two of them dimmed and marked stale](doc/img/multi.png)

It is built on the very same API and settings layer as Trndi (vendored as a submodule), so it supports the same backends - _Nightscout - Dexcom - FreeStyle Libre - Tandem Source - CareLink - xDrip_ - and shares Trndi's accounts: **a Trndi already set up needs no configuration at all**, and accounts added here are Trndi accounts too.

## Setting up accounts

Accounts live in Trndi's settings store, and each one needs a backend before it gets a tile. Set them up in whichever program is handier:

**In trndi-multi:** right-click the window and choose _Accounts_. Every account is a tab with the few things a tile needs: a nickname (the tile title), the system (Nightscout, Dexcom, and so on), its user and password, and the unit. The _+_ tab adds an account; it asks for the account name once, and that name cannot be changed afterwards (it is the key everything else is stored under, and Trndi cannot rename it either). _Remove account_ takes an account off the wall and, if you say so, erases its settings; kept settings come back when an account with the same name is added again. Nothing is written until _Save_, after which the tiles reload. CareLink takes the token data captured in a browser rather than a password, as described in Trndi's CareLink guide; that step is easier in Trndi.

**In Trndi:** the full walkthrough is in [Trndi's multi-user guide](https://github.com/slicke/trndi/blob/main/guides/Multiuser.md); the short version:

1. **Start Trndi** and open its settings (right-click the window).
2. **Add the accounts.** On the _Accounts_ page (under _App & system_ in the sidebar) click _+ Add_ and enter a name for each person. Give them a nickname and colour if you like: the nickname becomes the tile title. Close the window and save.
3. **Restart Trndi.** Now that more than one account exists, it asks which one to use at start-up. Pick one of the new accounts.
4. **Configure that account's backend** in settings (Nightscout, Dexcom, and so on), as you would for a single-user Trndi. Save and close.
5. **Repeat steps 3 and 4** for every account. Each account has its own backend, thresholds and unit; an account without a backend is skipped by trndi-multi.
6. **Start trndi-multi.** It reads the same settings store and shows one tile per configured account, the default account first.

Changes made in Trndi show up in trndi-multi at its next start. Both programs rewrite the account list when they save, so do not have both settings windows open at once: whichever saves last wins.

## How it works

- **One unit for the wall.** Accounts can use mmol/L and mg/dL side by side in Trndi. Here everything is shown in the first account's unit, so the wall reads as one thing.
- **Each account polls on its own.** Every account is fetched on its own thread, one request per reporting interval, timed to land just after the next reading is due. A slow login on one account never holds up the others.
- **Colours mean the same as in Trndi.** Green in range, red-orange above the high limit, red below the low one; where the account has a personal target band inside those limits, amber and blue for the room between. The thresholds are the account's own, applied exactly as Trndi applies them.
- **Old readings look old.** A reading the backend could only serve as a fallback, or one that has aged past two reporting intervals, dims the tile and marks the footer `stale`. The footer always shows the reading's time and age.
- **Rotated tokens are saved.** CareLink swaps its refresh token on every refresh and revokes the old one. trndi-multi writes the new one back to the account's settings the same way Trndi does, so neither program is left with a dead token at its next start.
- **No data says why.** An account that cannot connect shows the backend's error on its tile; the others carry on.

## Keys and flags

| Key | Action |
|-----|--------|
| `F5` | Refetch every account now |
| `F11` | Toggle full screen |
| `Esc` | Leave full screen (not in kiosk mode) |
| `Q` | Quit |
| Right-click | Menu: _Accounts_, refresh, full screen, quit. Not in kiosk mode, where a wall display's passwords should not be one click away. |

| Flag | Effect |
|------|--------|
| `--fullscreen` | Start full screen |
| `--kiosk` | For a dedicated wall display: full screen, pointer hidden, Escape ignored, and the machine and screen kept awake for as long as it runs. On Linux that holds a logind idle/sleep lock, the desktop session's own idle inhibition over D-Bus (GNOME, KDE and anything with a desktop portal) and turns off X11 blanking; macOS uses `caffeinate`, Windows `SetThreadExecutionState`. All best-effort, and released on exit. |

On macOS pass flags through the bundle: `open -a trndi-multi --args --kiosk`.

Full screen, however it was entered, adds a clock strip above the tiles with the time and date: a wall display has no panel or taskbar to show them. It goes away with full screen.

The grid refills the window on resize and picks the column count that gives the biggest tiles, so two accounts sit side by side in a wide window and one above the other in a tall one.

## Downloads

Every push to `main` that builds green on all platforms becomes a rolling `build-N` release on the [releases page](https://github.com/slicke/trndi-multi/releases), with:

| Asset | Notes |
|-------|-------|
| `trndi-multi-linux-amd64`, `trndi-multi-linux-arm64` | Needs the Qt6 LCL bindings (`libqt6pas6` on Debian/Ubuntu, `qt6pas` on Fedora) and libcurl installed. `chmod +x` and run. |
| `trndi-multi-windows-x64.zip` | The exe with `libcurl.dll` beside it. Unzip and run. |
| `trndi-multi-macos-arm64.dmg` | Unsigned `Trndi Multi.app` for Apple Silicon: open the image, drag it to Applications, then clear the quarantine flag once with `xattr -c "/Applications/Trndi Multi.app"` (the README inside the image walks through it). Reads Trndi's preferences domain (`com.slicke.Trndi`), so a Trndi set up on the Mac is all it needs. |

## Building

Needs Lazarus (lazbuild) with the LCL, and libcurl (the HTTP transport, as in trndi-cli). Clone with the submodule:

```
git clone --recurse-submodules https://github.com/slicke/trndi-multi.git
cd trndi-multi
make            # release build to bin/trndi-multi (Qt6 on Linux)
make debug      # debug build; also compiles in Trndi's debug backends
make install    # to /usr/local/bin
```

`make WIDGETSET=gtk2` (or any widgetset your Lazarus has) picks another LCL backend; the Makefile defaults to qt6 on Linux and BSD, cocoa on macOS. Windows builds with `.\make.ps1` (win32 widgetset) and needs `libcurl.dll` next to the exe.

The debug build knows Trndi's synthetic `API_D_*` backends, which is how the screenshot above was made: a scratch `Trndi.cfg` under `XDG_CONFIG_HOME` with six accounts pointed at them.

## Not (yet) here

Deliberately out of scope for now: account colours and thresholds (Trndi sets those, and the tiles honour them), per-account language, alarms and sounds, JavaScript extensions and the Web API. Trndi itself has all of those.

## Disclaimer

trndi-multi is not a medical device. The data it shows may be delayed, inaccurate or unavailable - do not make medical decisions based on it, and verify with your official devices. See [Trndi's disclaimer](https://github.com/slicke/trndi/blob/main/DISCLAIMER.md), which applies here in full.

## License

GPLv3, like Trndi. See [LICENSE](LICENSE).
