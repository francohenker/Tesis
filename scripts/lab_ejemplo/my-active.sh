#!/bin/sh
exec mysqladmin --no-defaults -S /srv/lab/my/mysqld.sock -uroot ping >/dev/null 2>&1
