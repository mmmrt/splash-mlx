# Splash-MLX

A menu bar control panel for local inference on Apple silicon. It drives two engines:

- **[Splash](https://github.com/incoai/splash)** — Inco AI's native engine
- **[mlx-serve](https://github.com/ddalcu/mlx-serve)** — a native Zig server for MLX models

Pick either one and Splash-MLX starts, stops and configures it for you. There is no window and no
Dock icon — it lives entirely in the menu bar.

**The engines do all the real work.** This is only a front end: everything that actually runs a
model belongs to the projects above.

## What it does

Click the icon and a menu pops up. The menu changes to match whichever engine you picked.

- **Engine** — pick Splash or mlx-serve. Only one can run at a time. Switch and the other one stops.
- **Model** — pick the model to load. The list comes from the engine you picked, so switch engines
  and the list switches too. Models somewhere weird? Point at the folder yourself in *Settings →
  Model folder*.
- **Start / Pause / Stop / Restart** — greyed out until they actually do something. Pause freezes it:
  memory stays held, CPU goes quiet.
- **Settings** — shows up once it is running. Each engine has its own options, and an option only
  appears if that engine really understands it — so you cannot pick something that breaks the start.

While it runs you can watch how fast it is going, how much memory it is using, and the address to
point your apps at.

The menu also shows how hot the machine is — CPU and GPU temperature, colour-coded green / orange /
red as it climbs, next to total power draw. That row works whether or not a model is running, since
it is about the Mac, not the engine. See [Temperatures](#temperatures) for the optional dependency.

## Temperatures

Apple silicon does not hand out temperatures through the usual commands:

- `pmset -g therm` reports only thermal *warnings*, and normally prints nothing at all
- `powermetrics` has no `smc` sampler on recent macOS, and refuses to run without root

So Splash-MLX reads the IOHID temperature sensors instead, via **[macmon](https://github.com/vladkens/macmon)** —
a sudoless monitor for Apple silicon. It is an optional dependency:

```bash
brew install macmon
```

With macmon installed you get real degrees Celsius. Without it the row falls back to the system
thermal state (`nominal` / `fair` / `serious` / `critical`), which is always available and needs no
extra tool, and the menu offers a clickable hint with the install command. Nothing else is affected.

Splash-MLX never installs macmon for you — that is your call. After installing it, the temperature
shows up within five seconds; no restart needed.

## Install

```bash
git clone https://github.com/mmmrt/splash-mlx.git
cd splash-mlx
./build.sh
open ~/Applications/SplashMLX.app
```

Needs Xcode Command Line Tools (`xcrun swiftc`, `iconutil`), Apple Silicon and macOS 13+.

You also need at least one of the engines:

```bash
brew install incoai/tap/splash

brew tap ddalcu/mlx-serve https://github.com/ddalcu/mlx-serve && brew install mlx-serve
```

## Configuration

Settings live in `~/Library/Application Support/SplashMLX/config.json`, with one section per engine,
so switching back and forth keeps each engine's model, port and flags as you left them.

## License

MIT
