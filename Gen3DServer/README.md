# Gen3DServer

A private gateway that turns one image (later, a few) into a wrap-around 3D
asset using interchangeable image-to-3D engines. It is a **research spike**:
the app talks to one engine-neutral contract, so no model is wired into
Convolution and the choice of engine (and its licence) is decided only if
something ships. Background and the model survey:
`reports/Wraparound 3D from digital artwork.md`.

Runs on `ai` (RTX 3090 24 GB, 62 GB RAM) under `/opt/gen3d`, reachable only
over Tailscale at `http://100.70.201.117:8787`.

## Layout

| Path (repo) | On the host | What |
| --- | --- | --- |
| `gateway/gateway.py` | `/opt/gen3d/src/gateway` | FastAPI gateway, systemd `gen3d-gateway` |
| `engines.json` | `/opt/gen3d/src/engines.json` | Engine registry: command, env, options, licence |
| `engines/<name>/install.sh` | `/opt/gen3d/envs/<name>` | Builds one engine's isolated env (micromamba, own CUDA toolkit) |
| `engines/<name>/worker.py` | | The engine's worker process |
| `deploy.sh` | | rsync + (re)start the gateway |

Host state outside the repo: `/opt/gen3d/engines/<name>` (upstream clones),
`/opt/gen3d/models` (weights), `/opt/gen3d/hf` (HF cache), `/opt/gen3d/jobs`,
`/opt/gen3d/logs`, `/opt/gen3d/gateway.token` (bearer token, mode 600, created
on first start; never print it).

## Contract (v1)

All routes except `/v1/health` need `Authorization: Bearer <token>`.

- `GET /v1/health` → `{ok, resident, queued}`
- `GET /v1/engines` → per engine: title, inputs, outputs, options, licence
- `POST /v1/jobs` (multipart) → `202` job
  - `image` (required; PNG with alpha is used as the mask), `mask` (optional),
    `views` (optional, repeated), `engine` (default `trellis2`), `options` (JSON string)
- `GET /v1/jobs/{id}` → `{status: queued|running|done|failed, progress, result, error, warnings}`
  - `result`: `files`, `timings` (seconds per stage), `peak_vram_mb`,
    `camera` (input-camera pose relative to the asset, or `null` when the engine
    doesn't know it), `engine_options`
- `GET /v1/jobs/{id}/files/{name}` → e.g. `model.glb`, `preview.mp4`

Assets are glTF binary. The app converts to USDZ itself (AnythingUSDZKit), so
the server never needs a USD toolchain.

```sh
TOKEN=$(ssh ai cat /opt/gen3d/gateway.token)   # into a variable, not the terminal
curl -s -H "Authorization: Bearer $TOKEN" -F image=@render.png \
  -F options='{"pipeline_type":"1024_cascade","preview":true}' http://100.70.201.117:8787/v1/jobs
```

## Scheduling

One GPU, one job and one resident engine at a time. A job for another engine
stops the resident worker first; an idle worker is stopped after
`GEN3D_IDLE_SECONDS` (600). Before an engine starts or a job runs, the gateway
unloads Ollama's resident models (`keep_alive: 0`), because Ollama shares the
3090. A chat in Open WebUI during a job can still reload one mid-job.

## Worker protocol

A worker reads one JSON job per line on stdin (`{id, dir, options, views}`;
the input is `dir/image.png`, optional `dir/mask.png`) and writes JSON events
per line on stdout: `ready` once loaded, then per job `progress`, `warning`,
and finally `done` (the `result` fields above, files written to `dir/out/`) or
`error`. Library output goes to stderr → `/opt/gen3d/logs/engine-<name>.log`.
Adding an engine = an `install.sh`, a `worker.py` and an `engines.json` entry.

## Engines

### trellis2 — Microsoft TRELLIS.2 4B

`engines/trellis2/install.sh` then `fetch_models.py` (with the env's python).
The env pins upstream's torch 2.6 / cu124 and builds flash-attn (prebuilt
wheel), nvdiffrast, nvdiffrec, CuMesh, FlexGEMM and o-voxel for sm_86.
Two substitutions in the local `pipeline.json`, made by `fetch_models.py`:

- DINOv3 ViT-L (`facebook/dinov3-vitl16-pretrain-lvd1689m`) is gated with
  manual approval. A public re-upload is used whose LFS pointer has the same
  git blob id as Meta's file (the pointer carries the SHA-256), and the
  download is checked against that SHA-256.
- The background remover RMBG-2.0 (gated, CC BY-NC) is replaced by
  `ZhengPeng7/BiRefNet` (same architecture, MIT). Images with alpha skip it.

TRELLIS.2 does not report the input camera, so `camera` is `null`; the front
projection bake has to fit it from the silhouette.

Measured on the 3090 (2026-11-18, upstream sample `T.png`, `1024_cascade`,
500k-triangle decimation, 2048 textures): 82 s generate + 21 s GLB export
warm, ~50 s model load on the first job, torch peak reserved ~9.4 GB
(nvidia-smi ~14.8 GB), a 32 MB GLB that AnythingUSDZ turns into a 69 MB USDZ.
The optional preview turntable adds 55 s.

## Gotchas

- `deploy.sh` uses plain `ssh` (a YubiKey/Touch ID prompt per connection).
  To reuse an open ssh-exec session, set
  `GEN3D_SSH="ssh -o ControlPath=$HOME/.ssh/claude-sessions/ixion_100_70_201_117"`
  (the socket is named `<user>_<host with dots as underscores>`).
- Upstream TRELLIS.2 needs `transformers<5` (5.x renamed DINOv3's `layer`)
  and `opencv-python-headless<5` (5.x can't read the preview HDRIs' EXR).

- The host has the NVIDIA driver but no CUDA toolkit; each env carries its
  own (conda `cuda-toolkit`). Extensions that link `-lcuda` need
  `LIBRARY_PATH=$ENV/lib/stubs` at build time.
- Docker on `ai` has no NVIDIA container runtime (deliberately, see
  `~/servers/ai.md`), which is why engines are envs and not containers.
