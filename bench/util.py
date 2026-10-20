"""Utilidades comunes: semillas, hashes, comandos, escritura atómica de JSON."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any, Sequence

log = logging.getLogger("bench")


class ErrorBench(Exception):
    """Error de configuración o de entorno que impide continuar."""


class CorridaInvalida(ErrorBench):
    """La ejecución no cumple los criterios de validez (Tabla 3.29)."""


def derivar_semilla(*partes: Any) -> int:
    """Semilla de 63 bits estable (SHA-256): independiente de PYTHONHASHSEED y de la versión de Python."""
    texto = "|".join(str(p) for p in partes)
    return int.from_bytes(hashlib.sha256(texto.encode("utf-8")).digest()[:8], "big") & ((1 << 63) - 1)


def sha256_bytes(datos: bytes) -> str:
    return hashlib.sha256(datos).hexdigest()


def sha256_archivo(ruta: str | Path, bloque: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for b in iter(lambda: f.read(bloque), b""):
            h.update(b)
    return h.hexdigest()


def hash_codigo() -> dict:
    """Huella del código que produce los resultados (paquete bench + SQL)."""
    raiz = Path(__file__).resolve().parent.parent
    h = hashlib.sha256()
    for a in sorted(list((raiz / "bench").glob("*.py")) + list((raiz / "sql").glob("*.sql"))):
        h.update(a.name.encode())
        h.update(a.read_bytes())
    git = None
    try:
        r = subprocess.run(["git", "-C", str(raiz), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            git = r.stdout.strip()
            if subprocess.run(["git", "-C", str(raiz), "status", "--porcelain"], capture_output=True,
                              text=True, timeout=5).stdout.strip():
                git += "+modificado"
    except (OSError, subprocess.SubprocessError):
        pass
    return {"sha256": h.hexdigest(), "git": git}


def ahora_utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def escribir_json(ruta: str | Path, obj: Any) -> None:
    """Escritura atómica: un corte de energía nunca deja un JSON a medias."""
    ruta = Path(ruta)
    ruta.parent.mkdir(parents=True, exist_ok=True)
    tmp = ruta.with_name(ruta.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, ruta)


def leer_json(ruta: str | Path) -> Any:
    with open(ruta, "r", encoding="utf-8") as f:
        return json.load(f)


def ejecutar_cmd(cmd: Sequence[str], *, timeout: float | None = None, check: bool = True,
                 **fmt: str) -> subprocess.CompletedProcess:
    """Ejecuta un comando (lista de argumentos, sin shell) sustituyendo {claves}."""
    cmd = [str(c).format(**fmt) for c in cmd]
    log.debug("cmd: %s", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise ErrorBench(f"Falló el comando {cmd!r} (código {r.returncode}): {(r.stderr or r.stdout).strip()[:500]}")
    return r


def configurar_logging(archivo: str | Path | None = None, nivel: int = logging.INFO) -> None:
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
    raiz = logging.getLogger("bench")
    raiz.setLevel(nivel)
    raiz.handlers.clear()
    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    raiz.addHandler(sh)
    if archivo:
        Path(archivo).parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(archivo, encoding="utf-8")
        fh.setFormatter(fmt)
        raiz.addHandler(fh)
