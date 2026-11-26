# Splash-MLX

A menu bar control panel for local inference on Apple silicon. It drives three engines:

- **[Splash](https://github.com/incoai/splash)** — Inco AI's native engine
- **[mlx-serve](https://github.com/ddalcu/mlx-serve)** — a native Zig server for MLX models
- **[mfluxible](https://github.com/wesbiggs/mfluxible)** — a streaming HTTP API for image
  generation on Apple silicon, built on [mflux](https://github.com/filipstrand/mflux)
  (Qwen-Image, FLUX, Z-Image and friends)

Pick one and Splash-MLX starts, stops and configures it for you. There is no window and no
Dock icon — it lives entirely in the menu bar.

**The engines do all the real work.** This is only a front end: everything that actually runs a
model belongs to the projects above.

## What it does

Click the icon and a menu pops up. The menu changes to match whichever engine you picked.

- **Engine** — pick Splash, mlx-serve or Mfluxible. Only one can run at a time. Switch and the
  other one stops.
- **Model** — pick the model to load. Only models already downloaded on this machine are listed —
  no phantom entries, no cloud catalogs. For the LLM engines the list comes from the engine you
  picked (for mlx-serve, its `list` output filtered to chat/completion types — image models never
  leak into the LLM menus); for mfluxible it is the Hugging Face cache, checked for complete
  snapshots and mapped back to the engine's own model keys. A *Custom…* entry is always there if
  you want to type a model yourself. Models somewhere weird? Point at the folder yourself in
  *Settings → Model folder*.
- **Start / Pause / Stop / Restart** — greyed out until they actually do something. Pause freezes it:
  memory stays held, CPU goes quiet.
- **Settings** — shows up once it is running. Each engine has its own options, and an option only
  appears if that engine really understands it — so you cannot pick something that breaks the start.

While it runs you can watch how fast it is going, how much memory it is using, and the address to
point your apps at. With mfluxible selected, that address serves an image API instead of a chat
one — see [Image generation](#image-generation-mfluxible).

The menu also shows how hot the machine is — CPU and GPU temperature, colour-coded green / orange /
red as it climbs, next to total power draw. That row works whether or not a model is running, since
it is about the Mac, not the engine. See [Temperatures](#temperatures) for the optional dependency.

## Image generation (mfluxible)

The third engine runs [mfluxible](https://github.com/wesbiggs/mfluxible), a resident HTTP server for
text-to-image (and strength-based image-to-image) on Apple silicon. One process serves one model.

Splash-MLX configures it entirely through environment variables — there are no server flags to
probe, so the Settings menu shows the variables it sets instead:

| Setting | Env var | Default |
|---|---|---|
| Model | `MFLUXIBLE_MODEL` | `qwen-image-2.1` |
| Quantize | `MFLUXIBLE_QUANTIZE` | `8` (8-bit; `4`, or `none` for full precision) |
| LoRA paths | `MFLUXIBLE_LORA_PATHS` | — (comma-separated `.safetensors`) |
| LoRA scales | `MFLUXIBLE_LORA_SCALES` | — |
| Port | `MFLUXIBLE_PORT` | `8420` |
| Output dir | `MFLUXIBLE_OUTPUT_DIR` | engine default |

It also sets `MFLUXIBLE_CONFIG=none` so a stray `mfluxible.toml` can never leak unknown keys into
the start, and it deliberately does **not** set `HF_ENDPOINT` — weights are meant to be on disk
already (the model list only shows complete local snapshots).

**The API is OpenAI-compatible**, so any OpenAI client works. With mfluxible running:

```bash
# base URL http://127.0.0.1:8420  ·  model name = the mfluxible key  ·  no API key (localhost)
curl -s http://127.0.0.1:8420/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-image-2.1","prompt":"a red apple on a white table","size":"1024x1024"}'
```

Other endpoints: `/v1/images/edits` (image-to-image, multipart), `/v1/models`,
`/mfluxible/v1/images/generations` (native, full parameter set), `/sdapi/v1/txt2img` (A1111),
`/health`, and a browser harness at `GET /` — which is what the menu's **Open Web UI** opens.
It binds to `127.0.0.1` only; exposing it anywhere else is your call (mfluxible supports optional
HTTP Basic auth via `MFLUXIBLE_BASIC_AUTH_USERNAME` / `MFLUXIBLE_BASIC_AUTH_PASSWORD`).

Best results with Qwen-Image-2.1, per the model's own docs: **40 steps, guidance 1.0** (it is
trained to be sampled without CFG), and **1024px or larger** — small sizes turn fine detail into a
pixel grid. LoRAs trained with mflux load here via the two LoRA settings above; a LoRA is baked in
at startup, so changing it restarts the engine.

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

# mfluxible: no brew formula yet — a venv is enough
python3.12 -m venv ~/.mfluxible/venv && ~/.mfluxible/venv/bin/pip install mfluxible
```

Splash-MLX finds the engines anywhere on PATH, plus the usual homes: brew prefixes,
`~/.local/lib/mlx-serve`, and `~/.mfluxible/venv/bin` for mfluxible (`MFLUXIBLE_BIN` overrides).

Model weights for mfluxible go in the standard Hugging Face cache
(`~/.cache/huggingface/hub/models--<org>--<name>`). The menu lists a model only once its pinned
snapshot is complete — a half-downloaded repo is not a model.

## Configuration

Settings live in `~/Library/Application Support/SplashMLX/config.json`, with one section per engine,
so switching back and forth keeps each engine's model, port and flags as you left them.

## License

MIT
