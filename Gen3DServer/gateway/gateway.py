"""gen3d gateway: one HTTP contract in front of interchangeable image-to-3D engines.

The app (and curl) only ever talk to this. Each engine is a worker process in
its own environment (engines.json), started on demand, one at a time: a job
for another engine stops the resident one first so its VRAM is free, and an
idle engine is stopped after GEN3D_IDLE_SECONDS so the GPU goes back to Ollama.
Ollama's resident models are unloaded before an engine starts.

Contract (v1), all routes but /v1/health need `Authorization: Bearer <token>`:
  GET  /v1/health
  GET  /v1/engines
  POST /v1/jobs            multipart: image, [mask], [views...], [engine], [options JSON]
  GET  /v1/jobs/{id}       status, progress, result metadata
  GET  /v1/jobs/{id}/files/{name}
"""
import asyncio
import contextlib
import json
import os
import secrets
import shutil
import signal
import time
import uuid
from pathlib import Path
from typing import Optional

import httpx
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse

ROOT = Path(os.environ.get("GEN3D_ROOT", "/opt/gen3d"))
JOBS = ROOT / "jobs"
ENGINES_FILE = Path(os.environ.get("GEN3D_ENGINES", ROOT / "src" / "engines.json"))
TOKEN_FILE = ROOT / "gateway.token"
IDLE_SECONDS = int(os.environ.get("GEN3D_IDLE_SECONDS", "600"))
OLLAMA = os.environ.get("GEN3D_OLLAMA", "http://127.0.0.1:11434")
MAX_UPLOAD = 64 << 20

app = FastAPI(title="gen3d")
queue: "asyncio.Queue[str]" = asyncio.Queue()
jobs: dict[str, dict] = {}


def engines() -> dict:
    with open(ENGINES_FILE) as f:
        return json.load(f)


def token() -> str:
    return TOKEN_FILE.read_text().strip()


def auth(authorization: Optional[str] = Header(None)):
    expected = "Bearer " + token()
    if not authorization or not secrets.compare_digest(authorization, expected):
        raise HTTPException(401, "missing or wrong token")


def save(job: dict):
    path = JOBS / job["id"] / "job.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, indent=2))
    tmp.replace(path)


def public(job: dict) -> dict:
    return {k: v for k, v in job.items() if k != "dir"}


# MARK: engine processes

class Engine:
    def __init__(self, name: str, spec: dict):
        self.name, self.spec = name, spec
        self.proc: Optional[asyncio.subprocess.Process] = None
        self.last_used = time.time()

    async def start(self):
        await free_ollama()
        env = dict(os.environ, **{k: str(v) for k, v in self.spec.get("env", {}).items()})
        log = open(ROOT / "logs" / f"engine-{self.name}.log", "ab")
        self.proc = await asyncio.create_subprocess_exec(
            *self.spec["command"], cwd=self.spec.get("cwd"), env=env,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=log,
            limit=1 << 20, start_new_session=True)
        event = await self.read()
        if event.get("event") != "ready":
            await self.stop()
            raise RuntimeError(f"{self.name} failed to start: {event.get('message', event)}")
        return event

    async def read(self) -> dict:
        line = await self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f"{self.name} exited (see logs/engine-{self.name}.log)")
        return json.loads(line)

    async def run(self, job: dict):
        self.last_used = time.time()
        msg = {"id": job["id"], "dir": job["dir"], "options": job["options"], "views": job["views"]}
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        await self.proc.stdin.drain()
        while True:
            event = await self.read()
            kind = event.get("event")
            if kind == "progress":
                job["progress"] = {"stage": event.get("stage"), "fraction": event.get("fraction")}
                save(job)
            elif kind == "warning":
                job.setdefault("warnings", []).append(event.get("message"))
            elif kind in ("done", "error"):
                self.last_used = time.time()
                return event

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                await asyncio.wait_for(self.proc.wait(), 30)
            except asyncio.TimeoutError:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self.proc.pid, signal.SIGKILL)
                await self.proc.wait()
        self.proc = None

    @property
    def alive(self) -> bool:
        return self.proc is not None and self.proc.returncode is None


resident: Optional[Engine] = None


async def free_ollama():
    """Unloads Ollama's resident models so the engine has the whole GPU."""
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            ps = (await client.get(f"{OLLAMA}/api/ps")).json()
            for model in ps.get("models", []):
                await client.post(f"{OLLAMA}/api/generate", json={"model": model["name"], "keep_alive": 0})
    except Exception:
        pass  # Ollama down or absent: nothing to free.


async def engine_for(name: str) -> Engine:
    global resident
    if resident and resident.name == name and resident.alive:
        return resident
    if resident:
        await resident.stop()
        resident = None
    spec = engines().get(name)
    if not spec:
        raise RuntimeError(f"unknown engine {name}")
    engine = Engine(name, spec)
    await engine.start()
    resident = engine
    return engine


async def worker_loop():
    while True:
        job_id = await queue.get()
        job = jobs[job_id]
        job.update(status="running", started=time.time())
        save(job)
        try:
            await free_ollama()
            engine = await engine_for(job["engine"])
            result = await engine.run(job)
            if result["event"] == "done":
                result.pop("event"); result.pop("id", None)
                job.update(status="done", result=result, progress={"stage": "done", "fraction": 1.0})
            else:
                job.update(status="failed", error=result.get("message"))
        except Exception as e:
            job.update(status="failed", error=str(e))
            if resident and not resident.alive:
                await resident.stop()
        job["finished"] = time.time()
        save(job)


async def idle_loop():
    global resident
    while True:
        await asyncio.sleep(30)
        if resident and queue.empty() and not any(j["status"] == "running" for j in jobs.values()) \
                and time.time() - resident.last_used > IDLE_SECONDS:
            await resident.stop()
            resident = None


@app.on_event("startup")
async def startup():
    JOBS.mkdir(parents=True, exist_ok=True)
    (ROOT / "logs").mkdir(exist_ok=True)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(32))
        TOKEN_FILE.chmod(0o600)
    for path in sorted(JOBS.glob("*/job.json")):
        with contextlib.suppress(Exception):
            job = json.loads(path.read_text())
            if job["status"] in ("queued", "running"):
                job.update(status="failed", error="gateway restarted")
                save(job)
            jobs[job["id"]] = job
    asyncio.create_task(worker_loop())
    asyncio.create_task(idle_loop())


@app.on_event("shutdown")
async def shutdown():
    if resident:
        await resident.stop()


# MARK: routes

@app.get("/v1/health")
async def health():
    return {"ok": True, "resident": resident.name if resident and resident.alive else None,
            "queued": queue.qsize()}


@app.get("/v1/engines", dependencies=[Depends(auth)])
async def list_engines():
    return {name: {k: spec.get(k) for k in ("title", "inputs", "outputs", "options", "licence")}
            for name, spec in engines().items()}


async def store(upload: UploadFile, path: Path):
    data = await upload.read()
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "upload too large")
    path.write_bytes(data)


@app.post("/v1/jobs", dependencies=[Depends(auth)])
async def create_job(image: UploadFile = File(...), mask: Optional[UploadFile] = File(None),
                     views: list[UploadFile] = File([]), engine: str = Form("trellis2"),
                     options: str = Form("{}")):
    if engine not in engines():
        raise HTTPException(400, f"unknown engine {engine}")
    try:
        opts = json.loads(options)
    except ValueError:
        raise HTTPException(400, "options must be JSON")
    job_id = uuid.uuid4().hex[:12]
    job_dir = JOBS / job_id
    (job_dir / "views").mkdir(parents=True)
    from PIL import Image  # normalise whatever came in to PNG
    await store(image, job_dir / "upload")
    try:
        Image.open(job_dir / "upload").save(job_dir / "image.png")
    except Exception:
        shutil.rmtree(job_dir)
        raise HTTPException(400, "image is not a readable picture")
    (job_dir / "upload").unlink()
    if mask:
        await store(mask, job_dir / "mask.png")
    view_names = []
    for i, view in enumerate(views):
        name = f"views/{i}.png"
        await store(view, job_dir / name)
        view_names.append(str(job_dir / name))
    job = {"id": job_id, "engine": engine, "options": opts, "views": view_names,
           "status": "queued", "created": time.time(), "dir": str(job_dir), "progress": None}
    jobs[job_id] = job
    save(job)
    await queue.put(job_id)
    return JSONResponse(public(job), status_code=202)


@app.get("/v1/jobs/{job_id}", dependencies=[Depends(auth)])
async def get_job(job_id: str):
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(404, "no such job")
    return public(job)


@app.get("/v1/jobs/{job_id}/files/{name}", dependencies=[Depends(auth)])
async def get_file(job_id: str, name: str):
    job = jobs.get(job_id)
    if not job or job["status"] != "done" or name not in job["result"]["files"]:
        raise HTTPException(404, "no such file")
    return FileResponse(Path(job["dir"]) / "out" / name)
