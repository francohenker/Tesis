"""Control de los motores: ciclo de vida, imágenes base y contadores internos.

Los comandos concretos (systemctl, rsync, ...) se definen en la configuración,
de modo que el mismo código sirve para Debian 12 con systemd o para otro entorno.
"""
from __future__ import annotations

import fnmatch
import hashlib
import os
import time
from pathlib import Path
from typing import Any

from .db import Conexion, esperar_conexion
from .util import ErrorBench, ejecutar_cmd, escribir_json, leer_json, log


class ControlMotor:
    def __init__(self, cfg, nombre: str):
        self.cfg, self.nombre = cfg, nombre
        self.m = cfg.motor(nombre)
        self.tipo: str = self.m["tipo"]
        self.datadir = Path(self.m["datadir"])
        self.dir_imagenes = Path(self.m["imagenes"])
        self.cmds = self.m["comandos"]
        self.fmt = {"servicio": self.m.get("servicio", ""), "datadir": str(self.datadir)}
        self.excluir = list(cfg.get("sistema.excluir_huella"))

    # ------------------------------------------------------------- imágenes
    def ruta_imagen(self, estrategia: str) -> Path:
        return self.dir_imagenes / estrategia

    def ruta_huella(self, estrategia: str) -> Path:
        return self.dir_imagenes / f"{estrategia}.huella.json"

    def existe_imagen(self, estrategia: str) -> bool:
        return self.ruta_imagen(estrategia).is_dir() and self.ruta_huella(estrategia).exists()

    # ----------------------------------------------------------- ciclo de vida
    def _cmd(self, clave: str, *, check: bool = True, timeout: float | None = 600, **extra):
        return ejecutar_cmd(self.cmds[clave], check=check, timeout=timeout, **{**self.fmt, **extra})

    def esta_activo(self) -> bool:
        if "activo" not in self.cmds:
            return False
        return self._cmd("activo", check=False, timeout=30).returncode == 0

    def detener(self) -> None:
        log.info("[%s] detener", self.nombre)
        self._cmd("detener", timeout=300)
        t0 = time.monotonic()
        while self.esta_activo():
            if time.monotonic() - t0 > 120:
                raise ErrorBench(f"{self.nombre}: el servicio sigue activo tras detenerlo")
            time.sleep(0.5)

    def iniciar(self) -> None:
        log.info("[%s] iniciar", self.nombre)
        self._cmd("iniciar", timeout=300)

    def vaciar_cache(self) -> None:
        """sync + drop_caches (paso 4). Requiere root; el comando es configurable."""
        ejecutar_cmd(["sync"], check=False, timeout=300)
        if "vaciar_cache" in self.cmds:
            self._cmd("vaciar_cache", timeout=120)

    def restaurar(self, estrategia: str) -> None:
        if not self.existe_imagen(estrategia):
            raise ErrorBench(f"No existe la imagen base «{estrategia}» de {self.nombre} en {self.dir_imagenes}. "
                             f"Créela con: python -m bench imagenes --motor {self.nombre}")
        log.info("[%s] restaurar imagen %s", self.nombre, estrategia)
        self._cmd("restaurar", timeout=3600, imagen=str(self.ruta_imagen(estrategia)))

    def copiar_a_imagen(self, estrategia: str) -> None:
        self.dir_imagenes.mkdir(parents=True, exist_ok=True)
        log.info("[%s] copiar datadir -> imagen %s", self.nombre, estrategia)
        self._cmd("copiar", timeout=7200, imagen=str(self.ruta_imagen(estrategia)))

    def esperar_disponible(self) -> Conexion:
        return esperar_conexion(self.m, self.cfg.get("general.espera_disponible_s"), exigir_cext=False)

    # ---------------------------------------------------------------- huellas
    def _archivos(self, raiz: Path) -> list[Path]:
        res = []
        for dp, _dn, fn in os.walk(raiz):
            for f in fn:
                if not any(fnmatch.fnmatch(f, p) for p in self.excluir):
                    res.append(Path(dp) / f)
        return sorted(res)

    def huella(self, raiz: Path, modo: str) -> dict[str, Any]:
        """'rapida': ruta, tamaño y fecha de modificación (ns) de cada archivo; 'completa': además el SHA-256.

        La fecha en nanosegundos es imprescindible: las páginas de un motor se modifican en su sitio
        sin cambiar el tamaño del archivo, y rsync -a conserva la fecha exacta de la imagen. Un archivo
        que no fue restaurado conserva la fecha de la corrida anterior y la huella lo delata.
        """
        h = hashlib.sha256()
        n = total = 0
        for a in self._archivos(raiz):
            st = a.stat()
            tam = st.st_size
            h.update(f"{a.relative_to(raiz)}\t{tam}\t{st.st_mtime_ns}\n".encode())
            if modo == "completa":
                hc = hashlib.sha256()
                with open(a, "rb") as f:
                    for b in iter(lambda: f.read(1 << 20), b""):
                        hc.update(b)
                h.update(hc.digest())
            n += 1
            total += tam
        return {"sha256": h.hexdigest(), "archivos": n, "bytes": total}

    def registrar_huella_imagen(self, estrategia: str, modo_completo: bool = True) -> dict:
        raiz = self.ruta_imagen(estrategia)
        reg = {"estrategia": estrategia, "rapida": self.huella(raiz, "rapida")}
        if modo_completo:
            reg["completa"] = self.huella(raiz, "completa")
        escribir_json(self.ruta_huella(estrategia), reg)
        return reg

    def verificar_restauracion(self, estrategia: str, modo: str = "rapida") -> dict:
        ref = leer_json(self.ruta_huella(estrategia))
        if modo not in ref:
            modo = "rapida"
        actual = self.huella(self.datadir, modo)
        return {"ok": actual["sha256"] == ref[modo]["sha256"], "modo": modo,
                "sha256": actual["sha256"], "esperado": ref[modo]["sha256"]}


# ---------------------------------------------------------- información
def version_motor(con: Conexion) -> str:
    return str(con.consultar("SELECT version()" if con.tipo == "postgresql" else "SELECT VERSION()")[0][0])


def parametros_motor(con: Conexion, nombres: list[str]) -> dict[str, str]:
    if not nombres:
        return {}
    if con.tipo == "postgresql":
        filas = con.consultar("SELECT name, setting, COALESCE(unit, '') FROM pg_settings WHERE name = ANY(%s)",
                              (list(nombres),))
        return {n: f"{v}{u}" for n, v, u in filas}
    out = {}
    for n in nombres:
        filas = con.consultar("SHOW VARIABLES LIKE %s", (n,))
        if filas:
            out[n] = str(filas[0][1])
    return out


def verificar_dominio(con: Conexion, dom) -> list[str]:
    """Compara los máximos de clave primaria con el dominio configurado (consultas baratas)."""
    problemas = []
    for tabla, col, esperado in (("usuarios", "id_usuario", dom.usuarios), ("marcas", "id_marca", dom.marcas),
                                 ("productos", "id_producto", dom.productos), ("venta", "id_venta", dom.ventas)):
        real = con.consultar(f"SELECT COALESCE(MAX({col}), 0) FROM {tabla}")[0][0]
        if int(real) < esperado:
            problemas.append(f"{tabla}.{col}: máximo real {real} < dominio configurado {esperado}")
    return problemas


# ------------------------------------------------------ contadores internos
_MYSQL_STATUS = ["Innodb_buffer_pool_read_requests", "Innodb_buffer_pool_reads", "Com_commit", "Com_rollback",
                 "Innodb_data_written", "Innodb_os_log_written", "Innodb_row_lock_waits", "Innodb_row_lock_time"]


def contadores(con: Conexion) -> dict[str, int]:
    """Contadores acumulados de diagnóstico (Tabla 3.32). Se usa la diferencia final - inicial."""
    out: dict[str, int] = {}
    if con.tipo == "postgresql":
        fila = con.consultar("SELECT xact_commit, xact_rollback, blks_read, blks_hit, deadlocks, temp_bytes "
                             "FROM pg_stat_database WHERE datname = current_database()")[0]
        for k, v in zip(("xact_commit", "xact_rollback", "blks_read", "blks_hit", "deadlocks", "temp_bytes"), fila):
            out[k] = int(v or 0)
        for sql in ("SELECT num_timed, num_requested FROM pg_stat_checkpointer",       # PostgreSQL >= 17
                    "SELECT checkpoints_timed, checkpoints_req FROM pg_stat_bgwriter"):  # PostgreSQL < 17
            try:
                f = con.consultar(sql)[0]
                out["checkpoints_timed"], out["checkpoints_req"] = int(f[0] or 0), int(f[1] or 0)
                break
            except Exception:
                continue
        try:
            f = con.consultar("SELECT COALESCE(SUM(reads),0), COALESCE(SUM(writes),0) FROM pg_stat_io")[0]
            out["io_reads"], out["io_writes"] = int(f[0]), int(f[1])
        except Exception:
            pass
    else:
        for fila in con.consultar("SHOW GLOBAL STATUS"):
            if fila[0] in _MYSQL_STATUS:
                try:
                    out[fila[0]] = int(fila[1])
                except ValueError:
                    pass
    return out


def delta_contadores(ini: dict[str, int], fin: dict[str, int]) -> dict[str, int]:
    return {k: fin[k] - ini.get(k, 0) for k in fin}


# ------------------------------------------- reconstrucción de índices (R)
_IDX_MOV_E0 = [("fk_movimientos_producto", ["id_producto"]), ("fk_movimientos_usuario", ["id_usuario_responsable"])]
_IDX_MOV = {
    "E1": _IDX_MOV_E0 + [("idx_movimientos_fecha", ["fecha_movimiento"]), ("idx_movimientos_tipo", ["tipo_movimiento"])],
    "E2": _IDX_MOV_E0 + [("idx_movimientos_producto_tipo_fecha", ["id_producto", "tipo_movimiento", "fecha_movimiento"])],
}


def indices_movimientos(estrategia: str) -> list[tuple[str, list[str]]]:
    return _IDX_MOV.get(estrategia, _IDX_MOV_E0)


def reconstruir_indices(con: Conexion, estrategia: str) -> list[dict]:
    """Fase R de W3: reconstruye cada índice de movimientos_inventario y mide el tiempo.

    PostgreSQL: REINDEX INDEX. MySQL: DROP INDEX + ADD INDEX en una sola sentencia
    (operación en línea; reconstruye solo el índice, sin reescribir la tabla).
    """
    res = []
    for nombre, cols in indices_movimientos(estrategia):
        if con.tipo == "postgresql":
            sql = f"REINDEX INDEX {nombre}"
        else:
            sql = (f"ALTER TABLE movimientos_inventario DROP INDEX {nombre}, "
                   f"ADD INDEX {nombre} ({', '.join(cols)})")
        t0 = time.perf_counter_ns()
        con.ejecutar(sql)
        res.append({"indice": nombre, "segundos": round((time.perf_counter_ns() - t0) / 1e9, 4)})
    return res
