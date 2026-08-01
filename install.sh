#!/bin/bash
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT=/var/check_backup_freeradius.sh
CONFIG=/etc/default/check_backup_freeradius
CRON_FILE=/etc/cron.d/check_backup_freeradius
LOGROTATE=/etc/logrotate.d/check_backup_freeradius
STATE_DIR=/var/lib/check_backup_freeradius
MONITOR_LOG=/var/log/check_backup_freeradius.log
CRON_LOG=/var/log/check_backup_freeradius_cron.log
LOCK_FILE=/var/run/check_backup_freeradius.lock
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_MONITOR="$BASE_DIR/monitor/check_backup_freeradius.sh"

[ "$(id -u)" -eq 0 ] || { echo 'ERRO: execute este instalador como root.'; exit 1; }
[ -f "$SOURCE_MONITOR" ] || { echo "ERRO: monitor não encontrado: $SOURCE_MONITOR"; exit 1; }
bash -n "$0" && bash -n "$SOURCE_MONITOR" || { echo 'ERRO: falha na validação de sintaxe.'; exit 1; }
for cmd in bash flock mysql curl timeout pgrep stat tail grep; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERRO: comando obrigatório ausente: $cmd"; exit 1; }
done

default_name="$(hostname 2>/dev/null || printf mk-auth)"
printf 'Nome deste MK-AUTH/VM [%s]: ' "$default_name"
read -r MKAUTH_NAME
MKAUTH_NAME="${MKAUTH_NAME:-$default_name}"
printf 'Deseja utilizar o envio de alertas pelo Telegram? [S/n]: '
read -r answer
case "$answer" in
    n|N|nao|NAO|não|NÃO) USAR_TELEGRAM=nao; TELEGRAM_BOT=; TELEGRAM_CHAT_ID= ;;
    *)
        USAR_TELEGRAM=sim
        printf 'Token do bot Telegram: '; read -r TELEGRAM_BOT
        while [ -z "$TELEGRAM_BOT" ]; do printf 'O token não pode ficar vazio. Token do bot Telegram: '; read -r TELEGRAM_BOT; done
        printf 'Chat ID do Telegram: '; read -r TELEGRAM_CHAT_ID
        while [ -z "$TELEGRAM_CHAT_ID" ]; do printf 'O Chat ID não pode ficar vazio. Chat ID do Telegram: '; read -r TELEGRAM_CHAT_ID; done
        ;;
esac

for item in "$SCRIPT" "$CONFIG" "$CRON_FILE" "$LOGROTATE"; do
    [ ! -e "$item" ] || { cp -a "$item" "${item}.bak-${TIMESTAMP}"; echo "Backup: ${item}.bak-${TIMESTAMP}"; }
done

cron_files="$({ [ -f /etc/crontab ] && echo /etc/crontab; find /etc/cron.d /var/spool/cron /var/spool/cron/crontabs -maxdepth 2 -type f 2>/dev/null; } | sort -u)"
while IFS= read -r file; do
    [ -f "$file" ] || continue
    [ "$file" = "$CRON_FILE" ] && continue
    if grep -Eq '^[[:space:]]*[^#].*check_backup_freeradius\.sh' "$file"; then
        cp -a "$file" "${file}.bak-${TIMESTAMP}"
        sed -i "/^[[:space:]]*[^#].*check_backup_freeradius\.sh/s|^|# DESATIVADO ${TIMESTAMP}: |" "$file"
        echo "Cron antigo desativado: $file"
    fi
done <<EOF
$cron_files
EOF

mkdir -p "$STATE_DIR"
touch "$MONITOR_LOG" "$CRON_LOG"
install -o root -g root -m 700 "$SOURCE_MONITOR" "$SCRIPT"
{
    printf 'MKAUTH_NAME=%q\n' "$MKAUTH_NAME"
    printf 'USAR_TELEGRAM=%q\n' "$USAR_TELEGRAM"
    printf 'TELEGRAM_BOT=%q\n' "$TELEGRAM_BOT"
    printf 'TELEGRAM_CHAT_ID=%q\n' "$TELEGRAM_CHAT_ID"
    printf 'COOLDOWN_SECONDS=180\n'
} > "$CONFIG"
chown root:root "$CONFIG" "$STATE_DIR" "$MONITOR_LOG" "$CRON_LOG"
chmod 600 "$CONFIG"; chmod 750 "$STATE_DIR"; chmod 640 "$MONITOR_LOG" "$CRON_LOG"

cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root timeout 120 $SCRIPT >> $CRON_LOG 2>&1
* * * * * root sleep 30; timeout 120 $SCRIPT >> $CRON_LOG 2>&1
EOF
chmod 644 "$CRON_FILE"; chown root:root "$CRON_FILE"
cat > "$LOGROTATE" <<EOF
$MONITOR_LOG $CRON_LOG {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root root
}
EOF
chmod 644 "$LOGROTATE"; chown root:root "$LOGROTATE"

rm -f "$STATE_DIR/radius.offset" "$STATE_DIR/radius.inode" "$STATE_DIR/last_successful_recovery" "$STATE_DIR/telegram_message_id" "$STATE_DIR/incident_start" "$STATE_DIR/incident_reason" "$LOCK_FILE"
bash -n "$SCRIPT" || { echo 'ERRO: monitor instalado falhou no bash -n.'; exit 1; }
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
    service cron restart 2>/dev/null || service crond restart 2>/dev/null || true
elif [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron restart 2>/dev/null || true
fi
"$SCRIPT" || true

if [ "$USAR_TELEGRAM" = sim ]; then
    echo 'Testando Telegram...'
    response="$(timeout 20 curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT}/sendMessage" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=✅ Monitor MK-AUTH instalado em $MKAUTH_NAME" 2>&1)"
    printf '%s' "$response" | grep -q '"ok":true' && echo 'Telegram: OK' || echo "Telegram: ERRO - $response"
fi
echo "Instalação concluída. Monitor: $SCRIPT | Configuração: $CONFIG | Cron: $CRON_FILE"
