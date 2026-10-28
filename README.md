# Pelican on the Beach

A pelican rides a bicycle along the shore, in the corner of your screen. While an agent works it pedals; more tokens per second means it pedals harder. The moment the work stops it coasts to a halt and looks out at the sea.

![The pelican pedalling while an agent works](pelican-demo.gif)

English · [中文](README.zh-CN.md)

## Install

macOS only, and it needs `swiftc` from the Xcode command line tools. One command builds the app and drops it into `~/Applications`:

```bash
./install.sh
```

Then open `~/Applications/Pelican.app`: double-click it, or press ⌘-space and type Pelican. Re-run the same command after changing the code.

What you get is a transparent window that floats above everything else. No Dock icon, and the only handle is a small bicycle in the menu bar.

## Handling it

Drag anywhere in the window to move it. The bicycle in the menu bar hides and shows it, offers three sizes, switches starting at login on or off, and quits. It comes back where you left it, at the size you left it.

## It changes vehicles

Pedal slowly and it is a bicycle. Push the rate up and it becomes a motorcycle, and back again when the work slows; there is nothing in between, so you never see a vehicle flash by on the way. Once it is on the motorcycle the speed keeps climbing with the rate instead of topping out there, so a big burst reads as faster riding, not just a different bike.

## When it stops

Once the tokens stop the pelican coasts to a halt, puts its near foot down on the sand and settles. One webbed foot takes the weight, the other stays on the pedal, and it watches the sea until work starts again. It waits a moment first, so a gap between two tool calls does not turn into a dismount.

## It follows the clock

Daytime is the bright turquoise beach. After four in the afternoon the sun drops and the light turns amber. Past seven it is night: stars come out, the moon takes the sun's place, and the bike throws a pool of light on the sand ahead. It reads the clock on your Mac, so there is nothing to set.

## What makes it pedal

Hermes, Codex and Claude Code running on this machine. Whichever one is spending tokens is the one moving the pedals, and none of them gets priority.

Hermes keeps a live lease for as long as a turn is running. Codex and Claude Code leave token counts in their session logs, and that is where the speed comes from. If a harness writes nothing readable, it falls back to how fast its log is growing.

Want it to watch other folders too? Put one path per line in `app/agents.txt`. That file is deliberately not in the repo.

## When something looks off

- Edited the scene in `app/pelican.html` and nothing changed: run `./install.sh` again. Every copy of the app draws the scene bundled inside itself.
- Window ended up off-screen: `defaults delete local.pelican.float origin`
- Want a different default width: `defaults write local.pelican.float width -float 480`

## Self-check

```bash
./check.sh
```

There is no test framework here, so this is a handful of checks that can actually fail: the page's JavaScript parses, the copy bundled into the app matches the source byte for byte, one headless frame proves the scene draws, the drivetrain turns the rear wheel twice per crank revolution, coasting freezes the crank while the wheels keep rolling, and the night palette really is a different one, every scrolling strip is one drawing plus an exact copy, which is what stops the sand from jumping at the seam, a parked pelican really does put a foot on the sand while a pedalling one keeps both feet on the pedals, a burst of tokens goes from bicycle to motorcycle in one clean swap with no third ride in between, the headlamp lights the sand in front rather than behind, and ten times the tokens really is a faster ride rather than just a different bike.

## Start it at login

Tick 开机自启 in the menu-bar menu and the system starts it for you at login; untick it and it stops. macOS lists it under Login Items, so it is nothing hidden.

## License

MIT. Use it, change it, ship it.
