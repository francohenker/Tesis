#!/bin/sh
exec su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /srv/lab/pg/data -w -t 120 -l /srv/lab/pg/log.txt start"
