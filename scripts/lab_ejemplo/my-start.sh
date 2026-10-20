#!/bin/sh
mysqld --defaults-file=/srv/lab/my/my.cnf --daemonize >/dev/null 2>&1 || exit 1
for i in $(seq 1 120); do mysqladmin --no-defaults -S /srv/lab/my/mysqld.sock -uroot ping >/dev/null 2>&1 && exit 0; sleep 1; done
exit 1
