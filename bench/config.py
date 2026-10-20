"""Carga y validación de la configuración del experimento (archivo TOML).

Toda decisión del experimento (duraciones, concurrencias, rutas, comandos de
control de los motores, dominio de los datos) vive en un único archivo de
configuración. Su SHA-256 se registra en cada resultado, de modo que cada
medición puede rastrearse hasta la configuración exacta que la produjo.
"""
from __future__ import annotations

import copy
import tomllib
from pathlib import Path
from typing import Any

from .util import ErrorBench, sha256_archivo

DEFECTOS: dict[str, Any] = {
    "general": {
        "directorio_resultados": "resultados",
        "repeticiones": 30,
        "piloto_repeticiones": 3,
        "concurrencias": [1, 10, 50, 100],
        "cooldown_s": 30,
        "reposo_cpu_max_pct": 5.0,
        "reposo_espera_max_s": 120,
        "timeout_ejecucion_s": 1800,
        "max_reintentos": 3,
        "timeout_conexion_s": 300,
        "espera_disponible_s": 300,
        "c6_concurrencia": 1,
        "c7_concurrencia": 10,
        "incluir_cache_fria": False,
    },
    "sistema": {
        "cpus_clientes": [],
        "dispositivo_datos": "",
        "fuente_recursos": "auto",
        "holgura_cliente_max_pct": 80.0,
        "exigir_cext_mysql": True,
        "swap_tolerancia": 0,
        "verificacion_imagen_por_corrida": "rapida",
        "excluir_huella": ["*.pid", "*.sock", "*.lock", "*.log"],
    },
    "ventanas": {
        "linea_base_n": 1000,
        "W1": {"calentamiento_s": 60, "medicion_s": 120},
        "W4": {"calentamiento_s": 120, "medicion_s": 300},
        "T9": {"calentamiento_s": 60, "medicion_s": 120},
        "SB1": {"calentamiento_s": 10, "medicion_s": 30},
        "w2_repeticiones_por_consulta": 5,
    },
    "w3": {"filas_e1": 500000, "lote_e1": 1000, "marcas_e2": 100, "factor_precio_e2": 1.05},
    "w4": {"lectura": 0.70, "compra": 0.20, "actualizacion": 0.10},
    "dataset": {
        "usuarios": 30000, "marcas": 800, "productos": 500000, "ventas": 5000000,
        "fecha_base_venta": "2021-01-01", "dias_venta": 1500,
        "fecha_base_mov": "2021-01-01", "dias_mov": 1800,
        "precio_min": 100, "precio_max": 50100,
        "frac_precio": 0.002, "frac_fecha_venta": 0.01, "frac_fecha_mov": 0.05, "frac_corte_e3": 0.48,
        "terminos_fts": [],
    },
    "validez": {
        "errores_tecnicos_max_pct": 1.0, "cobertura_monitor_min": 0.95,
        "ventana_efectiva_min": 0.95, "cv_tps_max_pct": 10.0,
    },
    "sysbench": {
        "binario": "sysbench", "base": "sbtest", "filas": 1000000, "hilos": [1, 10, 50],
        "tiempo_s": 60, "calentamiento_s": 10, "repeticiones": 5, "umbral_desviacion_pct": 20.0,
    },
}


def _fusionar(base: dict, extra: dict) -> dict:
    res = copy.deepcopy(base)
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(res.get(k), dict):
            res[k] = _fusionar(res[k], v)
        else:
            res[k] = copy.deepcopy(v)
    return res


class Config:
    """Envoltorio de solo lectura sobre el diccionario de configuración."""

    def __init__(self, datos: dict, ruta: Path | None = None, sha256: str = ""):
        self.datos, self.ruta, self.sha256 = datos, ruta, sha256

    @classmethod
    def cargar(cls, ruta: str | Path) -> "Config":
        ruta = Path(ruta).resolve()
        if not ruta.exists():
            raise ErrorBench(f"No existe el archivo de configuración: {ruta}")
        with open(ruta, "rb") as f:
            usuario = tomllib.load(f)
        cfg = cls(_fusionar(DEFECTOS, usuario), ruta, sha256_archivo(ruta))
        cfg.validar()
        return cfg

    def get(self, clave: str, defecto: Any = None) -> Any:
        nodo: Any = self.datos
        for parte in clave.split("."):
            if not isinstance(nodo, dict) or parte not in nodo:
                return defecto
            nodo = nodo[parte]
        return nodo

    def req(self, clave: str) -> Any:
        v = self.get(clave, None)
        if v is None:
            raise ErrorBench(f"Falta la clave obligatoria «{clave}» en la configuración")
        return v

    @property
    def raiz(self) -> Path:
        if self.ruta is None:
            return Path.cwd()
        return self.ruta.parent.parent if self.ruta.parent.name == "config" else self.ruta.parent

    def ruta_rel(self, p: str | Path) -> Path:
        p = Path(p)
        return p if p.is_absolute() else (self.raiz / p)

    @property
    def dir_resultados(self) -> Path:
        return self.ruta_rel(self.req("general.directorio_resultados"))

    @property
    def motores(self) -> dict[str, dict]:
        return self.datos.get("motores", {})

    def motor(self, nombre: str) -> dict:
        m = self.motores.get(nombre)
        if m is None:
            raise ErrorBench(f"Motor desconocido «{nombre}». Definidos: {sorted(self.motores)}")
        return m

    def validar(self) -> None:
        self.req("general.semilla_maestra")
        if not self.motores:
            raise ErrorBench("La configuración no define ningún motor ([motores.<nombre>])")
        for nombre, m in self.motores.items():
            for k in ("tipo", "host", "puerto", "usuario", "base", "datadir", "imagenes"):
                if k not in m:
                    raise ErrorBench(f"Motor «{nombre}»: falta la clave «{k}»")
            if m["tipo"] not in ("postgresql", "mysql"):
                raise ErrorBench(f"Motor «{nombre}»: tipo «{m['tipo']}» no soportado")
            for k in ("detener", "iniciar", "restaurar", "copiar"):
                if k not in m.get("comandos", {}):
                    raise ErrorBench(f"Motor «{nombre}»: falta comandos.{k}")
        c = self.get("general.concurrencias")
        if not c or any((not isinstance(x, int)) or x < 1 for x in c):
            raise ErrorBench("general.concurrencias debe ser una lista de enteros >= 1")
        if abs(sum(self.get("w4").values()) - 1.0) > 1e-9:
            raise ErrorBench("Las proporciones de [w4] deben sumar 1.0")
