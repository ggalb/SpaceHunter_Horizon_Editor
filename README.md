# Space Hunter — Horizon Editor

A local tool to build and edit **N.I.N.A. custom horizon (`.hrz`)** files, and
optionally slew a **Sky‑Watcher / GS Server** mount to horizon points to check
the sky is actually clear.

## What it does

- **Two views of your horizon:** a polar Alt/Az dome and a rectangular
  azimuth × altitude profile — single‑valued, exactly as N.I.N.A. reads it.
- **RA/Dec → Alt/Az converter** with time and azimuth nudging to trace a
  target's path across the sky.
- **Edit the horizon:** click to add/overwrite points, snap‑select and delete,
  multi‑level undo; open and save `.hrz` files directly (Chrome/Edge).
- **Sun safety overlay:** live Sun position, a 30° exclusion zone, and today's
  trajectory — plus a warning before slewing near the Sun.
- **Optional mount control** (slew to point / STOP / tracking) via a small
  local PowerShell bridge to GS Server — no extra software to install.

## Requirements

- Windows 10/11 with Chrome or Edge.
- For mount control: ASCOM Platform + GS Server + your mount's driver, and
  Windows PowerShell 5.1 (built in).

## Use

- **Horizon editing only:** double‑click `horizon_editor_local.html`.
- **With mount control:** run `start-bridge.cmd`, then open
  `http://localhost:5555` in Chrome/Edge, and Connect.

## Safety

Slewing points a real telescope. Keep the scope physically clear of
obstructions, use **STOP** to abort, and never point optics near the Sun — the
30° Sun‑exclusion confirm is a safeguard, not a guarantee.

## Files

| File | Purpose |
|---|---|
| `horizon_editor_local.html` | The app (open in Chrome/Edge) |
| `gss-bridge.ps1` | Local ASCOM ↔ GS Server bridge (serves the page + mount API) |
| `start-bridge.cmd` | Double‑click launcher for the bridge |
