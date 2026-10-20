#!/bin/sh
# Ajustes del sistema para las campañas (Tabla 3.25). Ejecutar como root ANTES de empezar y
# guardar la salida junto con los resultados:  sh scripts/preparar_sistema.sh | tee resultados/sistema.txt
# Los valores concretos son los de la tabla de la tesis [CONFIRMAR]; ajústelos allí y aquí a la vez.
set -u
echo "== fecha: $(date -u +%FT%TZ)"
# 1. frecuencia fija
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g"; done
# 2. sin páginas transparentes (THP) ni swap
[ -w /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled
[ -w /sys/kernel/mm/transparent_hugepage/defrag ] && echo never > /sys/kernel/mm/transparent_hugepage/defrag
sysctl -w vm.swappiness=0 >/dev/null
swapoff -a
# 3. sin tareas ajenas durante las campañas
for t in apt-daily.timer apt-daily-upgrade.timer fstrim.timer man-db.timer logrotate.timer; do
  systemctl stop "$t" 2>/dev/null; systemctl disable "$t" 2>/dev/null
done
# 4. los motores NO deben arrancar solos (los controla el orquestador)
echo "habilitados al arranque (deben quedar en 'disabled'):"; systemctl is-enabled postgresql mysql 2>&1
# 5. registro del estado resultante
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
echo "thp:      $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
echo "swap:     $(swapon --show --noheadings | wc -l) dispositivos activos"
echo "kernel:   $(uname -r)"
echo "cgroup v2: $( [ -f /sys/fs/cgroup/cgroup.controllers ] && echo sí || echo NO )"
echo "disco de datos:"; df -h /var/lib 2>/dev/null | tail -1
command -v smartctl >/dev/null && echo "SMART (guardar antes y después de las campañas):" && smartctl -A "${DISCO_SSD:-/dev/nvme0n1}" 2>&1 | head -30
