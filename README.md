# tesis-bench — cliente y orquestador de la comparación PostgreSQL 18 vs MySQL 9.7.2 LTS

Implementa lo definido en las secciones **3.4** (cargas), **3.5** (protocolo de ejecución) y **3.6**
(recolección de métricas) de la tesis. Un único archivo de configuración + este código + la semilla
maestra determinan por completo el experimento.

## 1. Qué hace

| Pieza | Módulo | Sección |
|---|---|---|
| Cargas W1–W4, T9 (L9) y SB1; operaciones L1–L9, A1–A4, T1, U1 | `consultas.py`, `cliente.py` | 3.4 |
| Un proceso por conexión, barreras, ventana común, latencia con `perf_counter_ns` | `cliente.py`, `nucleo.py` | 3.6.2 |
| Protocolo de 12 pasos (reposo, restaurar imagen, caché, calentamiento, línea base, ventana, validación) | `corrida.py` | 3.5 / Tabla 3.26 |
| Plan determinista, bloques aleatorizados, semillas, reanudación y reintentos | `plan.py`, `orquestador.py` | 3.5 / Tabla 3.28 |
| Imágenes base E0–E3, tiempos de creación de índices, huellas SHA-256 | `imagenes.py`, `motor.py` | 3.5 |
| CPU/RAM/E-S por cgroup v2 (o `/proc`), contadores internos, reconstrucción de índices | `recursos.py`, `motor.py` | 3.6.3 |
| Percentiles exactos, criterios de validez, IC95 (t de Student), CSV | `postproceso.py`, `validez.py`, `consolidar.py` | 3.6.4 / Tabla 3.29 |
| Verificación cruzada con Sysbench (`oltp_point_select`) | `verificacion.py` | — |

## 2. Instalación

```sh
python3 -m venv .venv && . .venv/bin/activate      # Python >= 3.11
pip install -r requirements.txt                   # versiones fijadas
python -m pytest -q tests                         # pruebas unitarias (no requieren base de datos)
```

Requisitos del equipo: Linux con systemd y cgroup v2, `rsync`, y ejecutar como **root** (control de
servicios y `drop_caches`). El driver de MySQL debe tener su extensión en C. **Atención:** la versión
`26.7.0` de `mysql-connector-python` publicada en PyPI se instaló aquí SIN esa extensión; por eso se fija la `9.7.0`.
En las pruebas, con Python puro el cliente subestimaba a MySQL (desviación del 27–29 % frente a Sysbench) y con la
extensión en C bajó al 3–13 %. La comprobación es
`python -c "import mysql.connector as m; print(m.HAVE_CEXT)"` → `True`; si no, el orquestador se niega a
medir (`exigir_cext_mysql`).

## 3. Procedimiento

```sh
cp config/experimento.toml config/mi_experimento.toml     # ajustar [CONFIRMAR]; fijar semilla_maestra UNA vez
export BENCH_PG_PASSWORD=...  BENCH_MYSQL_PASSWORD=...
sh scripts/preparar_sistema.sh | tee resultados/sistema.txt            # governor, THP, swap, tareas ajenas

# 1) cargar el dataset en cada motor (ver «Carga del dataset» más abajo) y comprobar la verificación final
# 2) imágenes base (una vez; también mide la creación de cada índice)
python -m bench --config config/mi_experimento.toml imagenes --motor postgres
python -m bench --config config/mi_experimento.toml imagenes --motor mysql
# 3) piloto: 3 repeticiones por combinación de la campaña principal; revisar validez y tiempos
python -m bench --config config/mi_experimento.toml run --piloto
# 4) campañas completas (reanudable: si se interrumpe, se vuelve a ejecutar el mismo comando)
python -m bench --config config/mi_experimento.toml plan
python -m bench --config config/mi_experimento.toml run
python -m bench --config config/mi_experimento.toml estado
# 5) resultados
python -m bench --config config/mi_experimento.toml consolidar
# 6) verificación cruzada con Sysbench
python -m bench --config config/mi_experimento.toml sysbench-preparar
python -m bench --config config/mi_experimento.toml sysbench
```

### Carga del dataset (sección 3.2)

```sh
# PostgreSQL (como superusuario)
psql -c "CREATE DATABASE tesis TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin LOCALE 'C.UTF-8'"
psql -d tesis -f sql/postgres_create_db.sql
psql -d tesis -f sql/postgres_populate_db.sql
# MySQL (como root, con el cliente mysql)
mysql -e "CREATE DATABASE tesis CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin"
mysql tesis < sql/mysql_create_db.sql
mysql tesis < sql/mysql_populate_db.sql
```

Los scripts de población no usan valores aleatorios: cada columna es una función determinista del número de fila
(con la función de dispersión `hk`, idéntica en ambos motores) y las claves se asignan de forma explícita, de modo que
los dos motores quedan con exactamente las mismas filas. Al final, cada script muestra tres verificaciones que deben
dar `OK`: volúmenes de la Tabla 3.2, integridad de las 17 claves foráneas y una huella del contenido por tabla
(la misma fórmula en ambos motores; el valor esperado se obtuvo con PostgreSQL). En MySQL las tablas se crean sin
claves foráneas; la sección 0 de `mysql_indexes_oe5.sql` (que aplica `imagenes`) crea los índices `fk_*` y después
agrega las claves, para que InnoDB no genere índices automáticos y E0 sea igual en ambos motores.

Otras opciones: `run --campanas principal indices_lectura …` (o `C1-C4`, `C5`, `C6`, `C7`, `C8`), `run --motor`,
`run --limite N`, `run --simular` (lista lo pendiente), `run --reintentar-agotadas`, y
`una --motor postgres --carga W1 --concurrencia 10` (una sola corrida, para depurar).

`config/prueba.toml` + `scripts/dataset_prueba.py` reproducen todo el flujo con un dataset reducido y
ventanas de pocos segundos. **No sirve para resultados de la tesis**, solo para verificar la instalación.

## 4. Reproducibilidad: qué se garantiza y cómo comprobarlo

1. **Plan determinista.** `manifiesto.json` se deriva de la configuración y de `semilla_maestra`; contiene `plan_sha256`.
   Dos personas con el mismo archivo obtienen el mismo plan y el mismo orden aleatorizado. Si la configuración
   cambia, el orquestador se niega a reanudar un plan distinto.
2. **Semillas por ejecución** = SHA-256(`semilla_maestra`, carga, concurrencia, bloque). Es independiente de
   `PYTHONHASHSEED` y de la versión de Python. Los dos motores y todas las estrategias del mismo bloque reciben
   el mismo flujo de parámetros (diseño apareado). Un reintento usa la misma semilla.
3. **Mismo estado inicial.** Antes de cada corrida se restaura la imagen base y se verifica su huella
   (`verificacion_imagen_por_corrida`); se comprueba además el dominio de las claves. La huella rápida incluye
   ruta, tamaño y fecha de modificación en nanosegundos; la completa, el SHA-256 del contenido. Si la restauración no
   coincide, la corrida se descarta antes de medir. **`rsync` debe usarse con `--modify-window=-1`**: por defecto omite
   archivos del mismo tamaño y fecha (en segundos) aunque su contenido difiera, y los motores modifican las páginas en su
   sitio; sin esa opción la restauración puede quedar a medias (ocurrió en las pruebas, ver `tests/`).
4. **Trazabilidad en cada resultado** (`<run_id>.json`): SHA-256 de la configuración, SHA-256 del código (y commit de
   git si existe), versión exacta de cada motor, parámetros relevantes del motor, kernel, governor, THP, swap,
   versiones de Python y de los drivers, y si MySQL usó la extensión en C.
5. **Datos crudos conservados**: latencia de cada operación (`.lat.gz`) y serie de recursos de 1 s (`.mon.csv`);
   todos los valores resumen pueden recalcularse a partir de ellos.
6. **Descartes documentados**: una ejecución inválida deja `<run_id>.descartada-N.json` con la causa; nunca se
   eliminan valores extremos de una ejecución válida.
7. **Pruebas automáticas** de percentiles, particiones, semillas, plan, parsers, validez y estadística.

## 5. Archivos de salida (`resultados/`)

```
manifiesto.json                  plan completo (con plan_sha256)
orquestador.log                  bitácora
datos/<campaña>/<run_id>.json    resultado válido (métricas + validez + trazabilidad)
datos/<campaña>/<run_id>.lat.gz  una fila por operación: op, estado, t (µs desde inicio de ventana), latencia (µs)
datos/<campaña>/<run_id>.mon.csv monitor de recursos, 1 fila/s
datos/<campaña>/*.descartada-N.json
consolidado/resumen_ejecuciones.csv     una fila por ejecución (unidad estadística)
consolidado/resumen_operaciones.csv     latencia por operación y ejecución
consolidado/resumen_combinaciones.csv   media, desvío, CV, IC95 por combinación (30 valores)
consolidado/fases_w3.csv                duración de E1, R (por índice), E2, E3, E4
consolidado/alertas_cv_tps.csv          combinaciones con CV de TPS > 10 %
verificacion/verificacion_sysbench.json razones PG/MySQL con el cliente propio y con Sysbench
```

Lectura del `.lat.gz` (Python): `from bench.postproceso import leer_lat; cab, cols = leer_lat(ruta)`.
Formato: línea JSON de cabecera, luego 4 columnas binarias consecutivas (`B op`, `B estado`, `I t`, `I lat`).

## 6. Decisiones y límites a tener presentes

* **TPS** = (operaciones completadas, incluidos eventos de negocio de T1) / duración efectiva de la ventana. La latencia
  incluye solo operaciones exitosas. Un descuento de stock sin filas afectadas en T1 se revierte y se cuenta como
  evento de negocio, no como error de rendimiento.
* **C5** se ejecuta separando W1 y W2 (240 ejecuciones en lugar de las 120 de la Tabla 3.28), para comparar cada
  carga con su referencia E0 de 1 conexión. Total del plan: **1.470** ejecuciones (1.590 con C8). Ajustar la Tabla 3.28.
* **L9 con términos numéricos**: por defecto busca el número de producto (una sola coincidencia). Si interesa una
  búsqueda con muchos resultados, defina `dataset.terminos_fts`.
* **Sin sentencias preparadas del servidor** en ambos motores; Sysbench se ejecuta con `--db-ps-mode=disable` y
  `--rand-type=uniform` por la misma razón.
* Los contadores de PostgreSQL se leen 1,2 s después del cierre de la ventana, porque el motor vuelca sus estadísticas
  con retardo.
* Cobertura del monitor y holgura del cliente solo se evalúan con ventanas ≥ 3 s y con `cpus_clientes` definido.
* El cliente es Python: con 100 conexiones la CPU del cliente puede saturar. El criterio de holgura (<80 %) lo advierte;
  reserve núcleos con `cpus_clientes`.
