#!/bin/sh
mysqladmin --no-defaults -S /srv/lab/my/mysqld.sock -uroot ping >/dev/null 2>&1 || exit 0
mysqladmin --no-defaults -S /srv/lab/my/mysqld.sock -uroot shutdown
for i in $(seq 1 120); do [ -e /srv/lab/my/mysqld.pid ] || exit 0; sleep 1; done
exit 1
