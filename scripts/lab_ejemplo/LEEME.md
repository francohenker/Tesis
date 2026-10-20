Scripts usados para probar el paquete en un contenedor SIN systemd (PostgreSQL 16 y MySQL 8.0 en /srv/lab).
Sirven de ejemplo de cómo adaptar `comandos.detener/iniciar/activo` de la configuración a un entorno
sin `systemctl`. Cada script debe ser idempotente: detener un motor ya detenido termina con éxito.
