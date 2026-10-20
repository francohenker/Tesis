#!/bin/sh
exec su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /srv/lab/pg/data status" >/dev/null 2>&1
