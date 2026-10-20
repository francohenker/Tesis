"""Medición de recursos (CPU, RAM, I/O) del motor y del sistema (sección 3.6.3).

Fuente preferida: cgroup v2 del servicio del motor. Cuenta de forma uniforme
todos los procesos del motor (PostgreSQL usa un proceso por conexión; MySQL
uno solo con hilos), por lo que medir un único PID sería incorrecto.

Fuente alternativa («proc»): suma los procesos descendientes del PID leído de
un pidfile. Es aproximada y existe para equipos sin cgroup v2 o para pruebas.
"""
from __future__ import annotations

import csv
import os
import time
from pathlib import Path
from typing import Any

CGROUP_RAIZ = Path("/sys/fs/cgroup")
CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100


def _leer(ruta: str | Path) -> str:
    with open(ruta, "r") as f:
        return f.read()


# ------------------------------------------------------------ analizadores
def parse_cpu_stat(texto: str) -> int:
    """cgroup cpu.stat -> microsegundos de CPU acumulados (usage_usec)."""
    for linea in texto.splitlines():
        p = linea.split()
        if len(p) == 2 and p[0] == "usage_usec":
            return int(p[1])
    raise ValueError("cpu.stat sin usage_usec")


def parse_memory_stat(texto: str) -> dict[str, int]:
    out = {"anon": 0, "shmem": 0, "file": 0}
    for linea in texto.splitlines():
        p = linea.split()
        if len(p) == 2 and p[0] in out:
            out[p[0]] = int(p[1])
    return out


def parse_io_stat(texto: str) -> dict[str, int]:
    out = {"rbytes": 0, "wbytes": 0, "rios": 0, "wios": 0}
    for linea in texto.splitlines():
        for campo in linea.split()[1:]:
            if "=" in campo:
                k, v = campo.split("=", 1)
                if k in out:
                    out[k] += int(v)
    return out


def parse_proc_stat(texto: str) -> dict[str, tuple[int, int]]:
    """/proc/stat -> {'cpu': (ocupado, total), 'cpu0': ...} en jiffies."""
    out: dict[str, tuple[int, int]] = {}
    for linea in texto.splitlines():
        if not linea.startswith("cpu"):
            continue
        p = linea.split()
        v = [int(x) for x in p[1:9]]
        v += [0] * (8 - len(v))
        user, nice, system, idle, iowait, irq, softirq, steal = v
        total = user + nice + system + idle + iowait + irq + softirq + steal
        out[p[0]] = (total - idle - iowait, total)
    return out


def parse_diskstats(texto: str, dispositivo: str) -> dict[str, int]:
    for linea in texto.splitlines():
        p = linea.split()
        if len(p) >= 10 and p[2] == dispositivo:
            return {"rd_ios": int(p[3]), "rd_sectors": int(p[5]), "wr_ios": int(p[7]), "wr_sectors": int(p[9])}
    return {"rd_ios": 0, "rd_sectors": 0, "wr_ios": 0, "wr_sectors": 0}


def parse_vmstat(texto: str) -> dict[str, int]:
    out = {"pswpin": 0, "pswpout": 0}
    for linea in texto.splitlines():
        p = linea.split()
        if len(p) == 2 and p[0] in out:
            out[p[0]] = int(p[1])
    return out


# ---------------------------------------------------- fuentes de recursos
class FuenteCgroup:
    nombre = "cgroup"

    def __init__(self, ruta: Path):
        self.ruta = Path(ruta)

    def snapshot(self) -> dict[str, Any]:
        cpu = parse_cpu_stat(_leer(self.ruta / "cpu.stat"))
        mem = parse_memory_stat(_leer(self.ruta / "memory.stat"))
        io = {"rbytes": 0, "wbytes": 0, "rios": 0, "wios": 0}
        try:
            io = parse_io_stat(_leer(self.ruta / "io.stat"))
        except OSError:
            pass
        return {"cpu_usec": cpu, "anon": mem["anon"], "shmem": mem["shmem"], "file": mem["file"], "io": io}

    @staticmethod
    def disponible(ruta: Path) -> bool:
        return (ruta / "cpu.stat").exists() and (ruta / "memory.stat").exists()


class FuenteProc:
    nombre = "proc"

    def __init__(self, pidfile: str | Path):
        self.pidfile = Path(pidfile)

    def _raiz(self) -> int | None:
        try:
            return int(_leer(self.pidfile).split()[0])
        except (OSError, ValueError, IndexError):
            return None

    @staticmethod
    def _hijos() -> dict[int, list[int]]:
        mapa: dict[int, list[int]] = {}
        for nombre in os.listdir("/proc"):
            if not nombre.isdigit():
                continue
            try:
                s = _leer(f"/proc/{nombre}/stat")
                ppid = int(s[s.rindex(")") + 2:].split()[1])
            except (OSError, ValueError, IndexError):
                continue
            mapa.setdefault(ppid, []).append(int(nombre))
        return mapa

    def pids(self) -> list[int]:
        raiz = self._raiz()
        if raiz is None:
            return []
        hijos = self._hijos()
        res, pila = [], [raiz]
        while pila:
            p = pila.pop()
            res.append(p)
            pila.extend(hijos.get(p, []))
        return res

    def snapshot(self) -> dict[str, Any]:
        ticks = anon = shmem = archivo = rb = wb = 0
        for pid in self.pids():
            try:
                s = _leer(f"/proc/{pid}/stat")
                c = s[s.rindex(")") + 2:].split()
                ticks += int(c[11]) + int(c[12])
                for linea in _leer(f"/proc/{pid}/status").splitlines():
                    if linea.startswith("RssAnon:"):
                        anon += int(linea.split()[1]) * 1024
                    elif linea.startswith("RssShmem:"):
                        shmem = max(shmem, int(linea.split()[1]) * 1024)
                    elif linea.startswith("RssFile:"):
                        archivo = max(archivo, int(linea.split()[1]) * 1024)
                try:
                    for linea in _leer(f"/proc/{pid}/io").splitlines():
                        if linea.startswith("read_bytes:"):
                            rb += int(linea.split()[1])
                        elif linea.startswith("write_bytes:"):
                            wb += int(linea.split()[1])
                except OSError:
                    pass
            except (OSError, ValueError, IndexError):
                continue
        return {"cpu_usec": int(ticks * 1_000_000 / CLK_TCK), "anon": anon, "shmem": shmem, "file": archivo,
                "io": {"rbytes": rb, "wbytes": wb, "rios": 0, "wios": 0}}


class FuenteNula:
    nombre = "ninguna"

    def snapshot(self) -> dict[str, Any]:
        return {"cpu_usec": 0, "anon": 0, "shmem": 0, "file": 0,
                "io": {"rbytes": 0, "wbytes": 0, "rios": 0, "wios": 0}}


def crear_fuente(sistema_cfg: dict, motor_cfg: dict):
    """cgroup v2 si existe el del servicio; si no, la alternativa por /proc."""
    modo = sistema_cfg.get("fuente_recursos", "auto")
    servicio = motor_cfg.get("servicio", "")
    ruta = Path(motor_cfg.get("cgroup_ruta") or (
        CGROUP_RAIZ / "system.slice" / (servicio if servicio.endswith(".service") else servicio + ".service")))
    if modo in ("auto", "cgroup") and servicio and FuenteCgroup.disponible(ruta):
        return FuenteCgroup(ruta)
    if modo == "cgroup":
        raise RuntimeError(f"fuente_recursos=cgroup pero no existe {ruta}")
    if modo in ("auto", "proc") and motor_cfg.get("pidfile"):
        return FuenteProc(motor_cfg["pidfile"])
    return FuenteNula()


# ----------------------------------------------------------- instantáneas
_DISCO_VACIO = {"rd_ios": 0, "rd_sectors": 0, "wr_ios": 0, "wr_sectors": 0}


def snapshot_sistema(dispositivo: str) -> dict[str, Any]:
    out: dict[str, Any] = {"cpu": parse_proc_stat(_leer("/proc/stat"))}
    try:
        out["disco"] = parse_diskstats(_leer("/proc/diskstats"), dispositivo) if dispositivo else dict(_DISCO_VACIO)
    except OSError:
        out["disco"] = dict(_DISCO_VACIO)
    out["swap"] = parse_vmstat(_leer("/proc/vmstat"))
    return out


def snapshot_completo(fuente, dispositivo: str) -> dict[str, Any]:
    return {"t_ns": time.monotonic_ns(), "motor": fuente.snapshot(), "sistema": snapshot_sistema(dispositivo)}


def uso_cpu_pct(a: dict, b: dict, cpus: list[int] | None = None) -> float:
    claves = [f"cpu{c}" for c in cpus] if cpus else ["cpu"]
    ocu = tot = 0
    for k in claves:
        if k in a["sistema"]["cpu"] and k in b["sistema"]["cpu"]:
            ocu += b["sistema"]["cpu"][k][0] - a["sistema"]["cpu"][k][0]
            tot += b["sistema"]["cpu"][k][1] - a["sistema"]["cpu"][k][1]
    return 100.0 * ocu / tot if tot > 0 else 0.0


def esperar_reposo(umbral_pct: float, espera_max_s: float, muestra_s: float = 3.0) -> float:
    """Espera a que el sistema esté en reposo. Devuelve la ocupación medida."""
    limite = time.monotonic() + espera_max_s
    while True:
        a = {"sistema": {"cpu": parse_proc_stat(_leer("/proc/stat"))}}
        time.sleep(muestra_s)
        b = {"sistema": {"cpu": parse_proc_stat(_leer("/proc/stat"))}}
        ult = uso_cpu_pct(a, b)
        if ult <= umbral_pct or time.monotonic() > limite:
            return ult


# --------------------------------------------------------------- monitor
CAMPOS_MONITOR = ["t_ns", "cpu_usec", "anon", "shmem", "file", "rd_ios", "rd_sectors", "wr_ios",
                  "wr_sectors", "pswpin", "pswpout", "cli_ocupado", "cli_total", "sis_ocupado", "sis_total"]


def _fila_monitor(fuente, dispositivo: str, cpus_cli: list[int]) -> list:
    s = snapshot_completo(fuente, dispositivo)
    m, sis = s["motor"], s["sistema"]
    claves = [f"cpu{c}" for c in cpus_cli] if cpus_cli else ["cpu"]
    co = sum(sis["cpu"].get(k, (0, 0))[0] for k in claves)
    ct = sum(sis["cpu"].get(k, (0, 0))[1] for k in claves)
    so, st = sis["cpu"]["cpu"]
    d, w = sis["disco"], sis["swap"]
    return [s["t_ns"], m["cpu_usec"], m["anon"], m["shmem"], m["file"], d["rd_ios"], d["rd_sectors"],
            d["wr_ios"], d["wr_sectors"], w["pswpin"], w["pswpout"], co, ct, so, st]


def bucle_monitor(sistema_cfg: dict, motor_cfg: dict, salida_csv: str, parar, listo,
                  cpus_cli: list[int], intervalo_s: float = 1.0) -> None:
    """Proceso monitor: una fila por segundo hasta que se activa el evento `parar`."""
    if cpus_cli and hasattr(os, "sched_setaffinity"):
        try:
            os.sched_setaffinity(0, set(int(c) for c in cpus_cli))
        except OSError:
            pass
    fuente = crear_fuente(sistema_cfg, motor_cfg)
    disp = sistema_cfg.get("dispositivo_datos", "")
    with open(salida_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(CAMPOS_MONITOR)
        listo.set()
        proximo = time.monotonic()
        while not parar.is_set():
            w.writerow(_fila_monitor(fuente, disp, cpus_cli))
            f.flush()
            proximo += intervalo_s
            demora = proximo - time.monotonic()
            if demora > 0:
                parar.wait(demora)
            else:
                proximo = time.monotonic()
        w.writerow(_fila_monitor(fuente, disp, cpus_cli))


def leer_monitor(ruta: str | Path) -> list[dict[str, int]]:
    with open(ruta, newline="") as f:
        return [{k: int(v) for k, v in fila.items()} for fila in csv.DictReader(f)]
