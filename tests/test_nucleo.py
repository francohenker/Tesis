"""Pruebas unitarias de las partes puras del paquete (sin base de datos)."""
import array
import math
import random
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bench import consolidar, plan, postproceso, recursos, validez  # noqa: E402
from bench.cliente import OP_IDS, OK, TEC, NEG, particion_contigua  # noqa: E402
from bench.config import DEFECTOS, Config, _fusionar  # noqa: E402
from bench.consultas import Dominio, construir_ops, elegir_op_w4, g_termino  # noqa: E402
from bench.imagenes import secciones_sql, sentencias  # noqa: E402
from bench.util import derivar_semilla  # noqa: E402


def cfg_prueba(**general) -> Config:
    d = _fusionar(DEFECTOS, {"general": {"semilla_maestra": 7, **general},
                             "motores": {"pg": {"tipo": "postgresql"}, "my": {"tipo": "mysql"}}})
    return Config(d)


# ------------------------------------------------------------ percentiles
def test_percentil_coincide_con_interpolacion_lineal_de_numpy():
    datos = list(range(1, 101))
    assert postproceso.percentil(datos, 50) == pytest.approx(50.5)
    assert postproceso.percentil(datos, 95) == pytest.approx(95.05)   # numpy.percentile(1..100, 95)
    assert postproceso.percentil(datos, 99) == pytest.approx(99.01)
    assert postproceso.percentil([5], 99) == 5
    assert postproceso.percentil(datos, 0) == 1 and postproceso.percentil(datos, 100) == 100


def test_resumen_valores_unidades_ms():
    r = postproceso.resumen_valores([1000, 2000, 3000, 4000])   # µs
    assert r["n"] == 4 and r["media"] == 2.5 and r["mediana"] == 2.5 and r["max"] == 4.0
    assert r["desvio"] == pytest.approx(1.290994, rel=1e-5)
    assert postproceso.resumen_valores([])["n"] == 0


def test_latencias_solo_cuentan_operaciones_ok():
    cols = {"op": array.array("B", [0, 0, 0, 13]), "st": array.array("B", [OK, TEC, OK, NEG]),
            "t": array.array("I", [1, 2, 3, 4]), "lat": array.array("I", [100, 999999, 300, 50])}
    r = postproceso.resumir_latencias(cols)
    assert r["conteo"] == {"ok": 2, "tecnicos": 1, "negocio": 1}
    assert r["latencia_ms"]["global"]["n"] == 2 and r["latencia_ms"]["L1"]["media"] == 0.2
    assert "T1" not in r["latencia_ms"]    # evento de negocio: no entra en latencias


def test_archivo_latencias_ida_y_vuelta(tmp_path):
    cols = {"op": array.array("B", [1, 2]), "st": array.array("B", [0, 1]),
            "t": array.array("I", [10, 20]), "lat": array.array("I", [111, 222])}
    postproceso.escribir_lat(tmp_path / "x.lat.gz", cols, {"run_id": "r"})
    cab, leido = postproceso.leer_lat(tmp_path / "x.lat.gz")
    assert cab["run_id"] == "r" and cab["n"] == 2 and cab["ops"] == OP_IDS
    assert all(list(leido[k]) == list(cols[k]) for k in cols)


# ----------------------------------------------------------- particiones
@pytest.mark.parametrize("n", [1, 3, 7, 100])
def test_particion_contigua_cubre_sin_solapar(n):
    cubiertos = []
    for k in range(n):
        r = particion_contigua(11, 1010, n, k)
        if r:
            cubiertos += list(range(r[0], r[1] + 1))
    assert cubiertos == list(range(11, 1011))


def test_particion_vacia():
    assert particion_contigua(5, 4, 3, 0) is None
    assert particion_contigua(1, 2, 5, 4) is None   # más clientes que filas


# --------------------------------------------------------- reproducibilidad
def test_semilla_estable_entre_ejecuciones_e_interpretes():
    # valor fijo: si cambia, los resultados dejarían de ser reproducibles entre versiones del código
    assert derivar_semilla(42, "W1", 10, 3) == derivar_semilla(42, "W1", 10, 3)
    assert derivar_semilla(42, "W1", 10, 3) != derivar_semilla(42, "W1", 10, 4)
    assert derivar_semilla(42, "W1", 10, 3) == 1414858752409103895   # SHA-256: no depende de la versión de Python
    assert derivar_semilla(1, "a") == 6151358694578356606
    assert 0 <= derivar_semilla("x") < 2 ** 63


def test_plan_determinista_y_balanceado():
    c = cfg_prueba()
    a, b = plan.generar_manifiesto(c), plan.generar_manifiesto(c)
    assert a["plan_sha256"] == b["plan_sha256"]
    assert a["total"] == 1470 - 0 and plan.resumen_plan(a) == {
        "principal": 960, "indices_lectura": 240, "indices_texto": 150, "indices_escritura": 120}
    # cada bloque de la campaña principal tiene las 32 combinaciones exactamente una vez
    for blq in (1, 15, 30):
        ids = [i for i in a["ejecuciones"] if i["campana"] == "principal" and i["bloque"] == blq]
        assert len(ids) == 32 and len({(i["motor"], i["carga"], i["concurrencia"]) for i in ids}) == 32
    otra = plan.generar_manifiesto(cfg_prueba())
    assert [i["run_id"] for i in a["ejecuciones"]] == [i["run_id"] for i in otra["ejecuciones"]]
    distinta = plan.generar_manifiesto(Config(_fusionar(c.datos, {"general": {"semilla_maestra": 8}})))
    assert distinta["plan_sha256"] != a["plan_sha256"]


def test_misma_semilla_para_ambos_motores_y_estrategias():
    m = plan.generar_manifiesto(cfg_prueba())
    por = {}
    for i in m["ejecuciones"]:
        por.setdefault((i["carga"], i["concurrencia"], i["bloque"]), set()).add(i["semilla"])
    assert all(len(v) == 1 for v in por.values())


def test_cache_fria_solo_si_se_pide():
    assert "fria" not in plan.resumen_plan(plan.generar_manifiesto(cfg_prueba()))
    m = plan.generar_manifiesto(cfg_prueba(incluir_cache_fria=True))
    assert plan.resumen_plan(m)["fria"] == 120 and all(not i["calentar"] for i in m["ejecuciones"] if i["campana"] == "fria")


# -------------------------------------------------------- operaciones
def test_parametros_identicos_para_ambos_motores():
    d = Dominio()
    opg, omy = construir_ops("postgresql", "E0"), construir_ops("mysql", "E0")
    for oid in ("L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "A2"):
        assert opg[oid].gen(random.Random(5), d) == omy[oid].gen(random.Random(5), d)


def test_l9_depende_de_motor_y_estrategia():
    assert "to_tsvector" in construir_ops("postgresql", "E0")["L9"].sql
    assert "LIKE" in construir_ops("mysql", "E0")["L9"].sql
    assert "MATCH" in construir_ops("mysql", "E3")["L9"].sql
    assert "to_tsvector" in construir_ops("postgresql", "E3-GiST")["L9"].sql
    assert construir_ops("mysql", "E0")["L9"].gen(random.Random(1), Dominio())[0].startswith("%")


def test_token_fts_respeta_longitud_minima_de_innodb():
    r = random.Random(3)
    assert all(len(g_termino(r, Dominio(productos=500000))[0]) >= 3 for _ in range(200))


def test_mezcla_w4_proporciones():
    r, n = random.Random(1), 20000
    cuenta = {"lectura": 0, "T1": 0, "U1": 0}
    for _ in range(n):
        o = elegir_op_w4(r, {"lectura": 0.7, "compra": 0.2, "actualizacion": 0.1})
        cuenta["T1" if o == "T1" else "U1" if o == "U1" else "lectura"] += 1
    assert cuenta["lectura"] / n == pytest.approx(0.7, abs=0.02)
    assert cuenta["T1"] / n == pytest.approx(0.2, abs=0.02)


# ------------------------------------------------------------- recursos
def test_parsers_de_recursos():
    assert recursos.parse_cpu_stat("usage_usec 1234\nuser_usec 1\n") == 1234
    assert recursos.parse_memory_stat("anon 10\nfile 20\nshmem 5\nother 9\n") == {"anon": 10, "shmem": 5, "file": 20}
    io = recursos.parse_io_stat("8:0 rbytes=100 wbytes=200 rios=3 wios=4 dbytes=0\n8:16 rbytes=1 wbytes=2 rios=1 wios=1")
    assert io == {"rbytes": 101, "wbytes": 202, "rios": 4, "wios": 5}
    cpu = recursos.parse_proc_stat("cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 10 0 5 80 5 0 0 0 0 0\n")
    assert cpu["cpu"] == (150, 1000) and cpu["cpu0"] == (15, 100)
    assert recursos.parse_vmstat("pswpin 5\nfoo 1\npswpout 7\n") == {"pswpin": 5, "pswpout": 7}
    ds = recursos.parse_diskstats("   8  0 sda 10 0 80 5 20 0 160 9 0 0 0\n", "sda")
    assert ds == {"rd_ios": 10, "rd_sectors": 80, "wr_ios": 20, "wr_sectors": 160}


# --------------------------------------------------------------- validez
def _ev(**o):
    base = dict(carga="W1", tipo_motor="mysql", estados_trabajadores=["ok"], conteo={"ok": 1000, "tecnicos": 0, "negocio": 0},
                errores={}, medicion_s=120, duracion_efectiva_s=120.0,
                recursos={"swap": {"pswpin": 0, "pswpout": 0}, "muestras_monitor": 120, "ventana_s": 120, "cliente_cpu_pct": 40.0},
                estado_inicial_ok=True, reposo_cpu_pct=1.0, contadores_delta={}, abortada=False, hay_cpus_cliente=True)
    base.update(o)
    return validez.evaluar(cfg_prueba(), **base)


def test_validez_caso_normal():
    r = _ev()
    assert r["valida"] and not r["advertencias"]


@pytest.mark.parametrize("cambio,motivo", [
    ({"conteo": {"ok": 980, "tecnicos": 20, "negocio": 0}}, "errores_tecnicos"),
    ({"estados_trabajadores": ["ok", "error"]}, "trabajador_fallido"),
    ({"duracion_efectiva_s": 100.0}, "ventana_efectiva"),
    ({"estado_inicial_ok": False}, "estado_inicial"),
    ({"abortada": True}, "tiempo_maximo_excedido"),
    ({"conteo": {"ok": 0, "tecnicos": 0, "negocio": 0}}, "sin_operaciones"),
])
def test_validez_descarta(cambio, motivo):
    r = _ev(**cambio)
    assert not r["valida"] and motivo in r["motivo_descarte"]


def test_validez_paginacion_y_cobertura():
    base = {"swap": {"pswpin": 0, "pswpout": 5}, "muestras_monitor": 120, "ventana_s": 120, "cliente_cpu_pct": 10.0}
    assert "paginacion" in _ev(recursos=base)["motivo_descarte"]
    base = {"swap": {"pswpin": 0, "pswpout": 0}, "muestras_monitor": 60, "ventana_s": 120, "cliente_cpu_pct": 10.0}
    assert "cobertura_monitor" in _ev(recursos=base)["motivo_descarte"]


def test_validez_advertencias_no_descartan():
    r = _ev(recursos={"swap": {"pswpin": 0, "pswpout": 0}, "muestras_monitor": 120, "ventana_s": 120, "cliente_cpu_pct": 95.0})
    assert r["valida"] and "holgura_cliente_insuficiente" in r["advertencias"]
    r = _ev(carga="W4", tipo_motor="postgresql", contadores_delta={"checkpoints_timed": 0, "checkpoints_req": 0})
    assert r["valida"] and any("checkpoint" in a for a in r["advertencias"])


# ------------------------------------------------------------ estadística
def test_ic95_t_student():
    e = consolidar.estadisticos([10.0, 12.0, 11.0, 13.0, 9.0])
    assert e["media"] == 11.0 and e["desvio"] == pytest.approx(math.sqrt(2.5))
    assert e["ic95_sup"] - e["media"] == pytest.approx(2.776 * math.sqrt(2.5) / math.sqrt(5), rel=1e-4)
    assert consolidar.t975(30) == 2.042 and consolidar.t975(500) == 1.96
    assert 2.0 < consolidar.t975(50) < 2.021
    assert consolidar.estadisticos([])["n"] == 0
    assert consolidar.estadisticos([5.0])["ic95_inf"] is None


# --------------------------------------------------------------- SQL
def test_secciones_de_los_scripts_de_indices():
    raiz = Path(__file__).resolve().parent.parent / "sql"
    pg = secciones_sql((raiz / "postgres_indexes_oe5.sql").read_text(encoding="utf-8"))
    my = secciones_sql((raiz / "mysql_indexes_oe5.sql").read_text(encoding="utf-8"))
    assert {"0", "2", "3", "4A", "4B", "6"} <= set(pg) and {"0", "2", "3", "4", "6"} <= set(my)
    assert [len(sentencias(pg[k])) for k in ("0", "2", "3", "4A", "4B")] == [13, 12, 7, 3, 3]
    assert [len(sentencias(my[k])) for k in ("0", "2", "3", "4")] == [13, 12, 7, 3]
    assert all(s.upper().startswith("CREATE") for k in ("2", "3") for s in sentencias(pg[k]))


# ------------------------------------------------- restauración de imágenes
def _ctl(tmp_path):
    from bench.motor import ControlMotor
    datos = _fusionar(DEFECTOS, {"general": {"semilla_maestra": 1}, "motores": {"x": {
        "tipo": "postgresql", "host": "h", "puerto": 1, "usuario": "u", "base": "b",
        "datadir": str(tmp_path / "data"), "imagenes": str(tmp_path / "img"), "comandos": {}}}})
    return ControlMotor(Config(datos), "x")


def test_huella_rapida_detecta_cambio_in_situ_sin_variar_el_tamano(tmp_path):
    import os
    ctl = _ctl(tmp_path)
    d = tmp_path / "data"
    d.mkdir()
    (d / "pagina").write_bytes(b"A" * 8192)
    h0 = ctl.huella(d, "rapida")["sha256"]
    st = os.stat(d / "pagina")
    (d / "pagina").write_bytes(b"B" * 8192)                       # mismo tamaño, otro contenido
    os.utime(d / "pagina", ns=(st.st_atime_ns, st.st_mtime_ns + 5_000_000))
    assert ctl.huella(d, "rapida")["sha256"] != h0
    assert ctl.huella(d, "completa")["sha256"] != ctl.huella(d, "rapida")["sha256"]


def test_huella_ignora_pid_y_logs(tmp_path):
    ctl = _ctl(tmp_path)
    d = tmp_path / "data"
    d.mkdir()
    (d / "datos").write_bytes(b"x")
    h0 = ctl.huella(d, "rapida")["sha256"]
    (d / "postmaster.pid").write_text("1")
    (d / "error.log").write_text("x")
    assert ctl.huella(d, "rapida")["sha256"] == h0


def test_rsync_con_ventana_exacta_restaura_archivos_del_mismo_tamano(tmp_path):
    """Regresión: rsync por defecto omite un archivo del mismo tamaño y fecha (en segundos) aunque difiera."""
    import os
    import shutil
    import subprocess
    if shutil.which("rsync") is None:
        pytest.skip("rsync no disponible")
    img, dat = tmp_path / "img", tmp_path / "dat"
    img.mkdir(); dat.mkdir()
    (img / "f").write_bytes(b"IMAGEN!")
    segundos = int(os.stat(img / "f").st_mtime)
    (dat / "f").write_bytes(b"CORRIDA")                           # misma longitud
    os.utime(dat / "f", (segundos, segundos))
    por_defecto = tmp_path / "d2"
    shutil.copytree(dat, por_defecto)
    subprocess.run(["rsync", "-a", "--delete", f"{img}/", f"{por_defecto}/"], check=True)
    assert (por_defecto / "f").read_bytes() == b"CORRIDA"          # el comportamiento peligroso
    subprocess.run(["rsync", "-a", "--delete", "--modify-window=-1", f"{img}/", f"{dat}/"], check=True)
    assert (dat / "f").read_bytes() == b"IMAGEN!"
    assert os.stat(dat / "f").st_mtime_ns == os.stat(img / "f").st_mtime_ns


def test_configuracion_real_usa_rsync_exacto():
    raiz = Path(__file__).resolve().parent.parent / "config"
    for nombre in ("experimento.toml", "prueba.toml"):
        c = Config.cargar(raiz / nombre)
        for m in c.motores.values():
            for clave in ("restaurar", "copiar"):
                assert "--modify-window=-1" in m["comandos"][clave], f"{nombre}: {clave}"
