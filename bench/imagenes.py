"""Creación de las imágenes base por motor y estrategia (E0 a E3), sección 3.5.

Precondición: el directorio de datos del motor contiene el dataset ya cargado
(scripts de creación y población) y NO tiene todavía los índices del script OE5.

    E0  = datos cargados + sección 0 (índices de claves foráneas) + estadísticas
    E1  = E0 + sección 2        E2 = E0 + sección 3
    E3  = E0 + sección 4A/4B (PostgreSQL: GIN, GiST) o 4 (MySQL: FULLTEXT)

Cada estrategia parte de la imagen E0 restaurada, de modo que las cuatro
comparten exactamente el mismo estado físico de los datos. Se registra el tiempo de
creación de cada índice (OE4), sus tamaños y la huella SHA-256 de la imagen.
"""
from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any

from . import motor as mot
from .config import Config
from .db import Conexion
from .util import ErrorBench, escribir_json, log

RAIZ_SQL = Path(__file__).resolve().parent.parent / "sql"

SECCIONES_DEFECTO = {
    "postgresql": {"E1": ["2"], "E2": ["3"], "E3-GIN": ["4A"], "E3-GiST": ["4B"]},
    "mysql": {"E1": ["2"], "E2": ["3"], "E3": ["4"]},
}
_RE_ENC = re.compile(r"^-- (\d+[AB]?)\. ", re.M)


def secciones_sql(texto: str) -> dict[str, str]:
    """Divide el script OE5 en sus secciones numeradas («-- 2. E1 - ...»)."""
    marcas = list(_RE_ENC.finditer(texto))
    res: dict[str, str] = {}
    for i, m in enumerate(marcas):
        ini = m.start()
        fin = marcas[i + 1].start() if i + 1 < len(marcas) else len(texto)
        cuerpo = texto[ini:fin]
        # la línea «-- ====» que abre la sección siguiente quedó al final de ésta: se descarta
        cuerpo = re.sub(r"\n-- =+\s*$", "\n", cuerpo.rstrip() + "\n")
        res[m.group(1)] = cuerpo
    return res


def sentencias(sql: str) -> list[str]:
    """Sentencias de una sección (sin comentarios ni metacomandos de psql). No soporta DELIMITER."""
    limpias = []
    for linea in sql.splitlines():
        s = linea.strip()
        if not s or s.startswith("--") or s.startswith("\\"):
            continue
        if s.upper().startswith("DELIMITER"):
            raise ErrorBench("La sección contiene DELIMITER: aplíquela con el cliente nativo del motor")
        limpias.append(linea)
    texto = "\n".join(limpias)
    return [p.strip() for p in re.split(r";\s*(?:\n|$)", texto) if p.strip()]


_RE_INDICE = re.compile(r"CREATE\s+(?:UNIQUE\s+|FULLTEXT\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\S+)", re.I)


def aplicar_seccion(con: Conexion, sql: str) -> list[dict]:
    res = []
    for s in sentencias(sql):
        t0 = time.perf_counter()
        con.ejecutar_leyendo(s)
        dur = time.perf_counter() - t0
        m = _RE_INDICE.match(s)
        res.append({"indice": m.group(1).strip('`"') if m else None, "segundos": round(dur, 4),
                    "sql": " ".join(s.split())[:200]})
    return res


def tamanos(con: Conexion) -> dict[str, Any]:
    """Tamaño en bytes de cada índice y de cada tabla (sección 7 del script)."""
    try:
        if con.tipo == "postgresql":
            idx = con.consultar(
                "SELECT c.relname, pg_relation_size(c.oid) FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid "
                "JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace "
                "WHERE n.nspname = 'public' ORDER BY 1")
            tab = con.consultar(
                "SELECT c.relname, pg_table_size(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY 1")
        else:
            idx = con.consultar(
                "SELECT CONCAT(table_name, '.', index_name), stat_value * @@innodb_page_size "
                "FROM mysql.innodb_index_stats WHERE database_name = DATABASE() AND stat_name = 'size' ORDER BY 1")
            tab = con.consultar(
                "SELECT table_name, data_length FROM information_schema.tables "
                "WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY 1")
        return {"indices": {str(k): int(v or 0) for k, v in idx}, "tablas": {str(k): int(v or 0) for k, v in tab}}
    except Exception as e:  # noqa: BLE001
        log.warning("no se pudieron leer los tamaños: %s", e)
        return {"indices": {}, "tablas": {}}


def estadisticas(con: Conexion, secs: dict[str, str]) -> None:
    """Sección 6 (ANALYZE). En PostgreSQL además VACUUM (ANALYZE): actualiza el mapa de visibilidad."""
    aplicar_seccion(con, secs["6"])
    if con.tipo == "postgresql":
        con.ejecutar("VACUUM (ANALYZE)")


def estrategias_de(cfg: Config, motor: str) -> list[str]:
    m = cfg.motor(motor)
    return ["E0"] + list(m.get("secciones", SECCIONES_DEFECTO[m["tipo"]]).keys())


def crear_imagenes(cfg: Config, motor: str, estrategias: list[str] | None = None, *,
                   huella_completa: bool = True) -> dict[str, dict]:
    ctl = mot.ControlMotor(cfg, motor)
    m = cfg.motor(motor)
    script = Path(cfg.ruta_rel(m["script_indices"])) if m.get("script_indices") else (
        RAIZ_SQL / ("postgres_indexes_oe5.sql" if ctl.tipo == "postgresql" else "mysql_indexes_oe5.sql"))
    secs = secciones_sql(script.read_text(encoding="utf-8"))
    mapa = m.get("secciones", SECCIONES_DEFECTO[ctl.tipo])
    pedidas = estrategias or estrategias_de(cfg, motor)
    for e in pedidas:
        if e != "E0" and e not in mapa:
            raise ErrorBench(f"Estrategia desconocida «{e}» para {motor}. Válidas: E0, {', '.join(mapa)}")
    informe: dict[str, dict] = {}

    def construir(est: str, secciones: list[str], desde: str | None) -> None:
        if desde:
            ctl.detener()
            ctl.restaurar(desde)
        else:
            ctl.detener()
        ctl.iniciar()
        con = ctl.esperar_disponible()
        try:
            version = mot.version_motor(con)
            creados: list[dict] = []
            for s in secciones:
                creados += aplicar_seccion(con, secs[s])
            estadisticas(con, secs)
            tam = tamanos(con)
        finally:
            con.cerrar()
        ctl.detener()
        ctl.copiar_a_imagen(est)
        huella = ctl.registrar_huella_imagen(est, huella_completa)
        informe[est] = {"estrategia": est, "motor": motor, "version_motor": version, "secciones": secciones,
                        "script_indices": script.name, "construccion": creados, "tamanos": tam, "huella": huella}
        escribir_json(ctl.dir_imagenes / f"{est}.construccion.json", informe[est])
        log.info("[%s] imagen %s lista (%d índices creados)", motor, est, len([c for c in creados if c["indice"]]))

    if "E0" in pedidas:
        construir("E0", ["0"], None)
    elif not ctl.existe_imagen("E0"):
        raise ErrorBench(f"Falta la imagen E0 de {motor}; es la base de las demás estrategias")
    for est in pedidas:
        if est != "E0":
            construir(est, mapa[est], "E0")
    ctl.detener()
    return informe
