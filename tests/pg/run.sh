#!/bin/bash
# usage: run.sh <dbname> <sql dir>   -> fresh database with stub + all numbered files except 02/07/25
DB=$1; DIR=$2
su postgres -c "psql -q -c 'drop database if exists $DB' -c 'create database $DB'" >/dev/null
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d $DB -f /home/claude/ld/pg/stub.sql" 2>&1 | grep -v NOTICE
for f in $(ls $DIR/*.sql | sort -V); do b=$(basename $f); case $b in 02_*|07_*|25_*) continue;; esac
  out=$(su postgres -c "psql -q -v ON_ERROR_STOP=1 -d $DB -f $f" 2>&1 | grep -v 'NOTICE\|^$' ); [ -n "$out" ] && echo "== $b: $(echo "$out" | head -3)"; done; echo done
