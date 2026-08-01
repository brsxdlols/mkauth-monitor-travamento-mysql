#!/bin/bash
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" -ne 0 ]; then
    echo 'ERRO: execute este desinstalador como root.'
    exit 1
fi

printf 'Deseja preservar logs e backups? [S/n]: '
read -r answer
preserve=sim
case "$answer" in n|N|nao|NAO|não|NÃO) preserve=nao;; esac

rm -f /etc/cron.d/check_backup_freeradius
rm -f /var/check_backup_freeradius.sh
rm -f /etc/default/check_backup_freeradius
rm -f /etc/logrotate.d/check_backup_freeradius
rm -f /var/run/check_backup_freeradius.lock
rm -rf /var/lib/check_backup_freeradius

if [ "$preserve" = nao ]; then
    rm -f /var/log/check_backup_freeradius.log /var/log/check_backup_freeradius.log.*
    rm -f /var/log/check_backup_freeradius_cron.log /var/log/check_backup_freeradius_cron.log.*
    rm -f /var/check_backup_freeradius.sh.bak-*
    rm -f /etc/default/check_backup_freeradius.bak-*
    rm -f /etc/cron.d/check_backup_freeradius.bak-*
    rm -f /etc/logrotate.d/check_backup_freeradius.bak-*
fi

echo 'Monitor removido. Nenhum arquivo do MK-AUTH foi alterado ou removido.'
