#!/bin/bash

set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG=/etc/default/check_backup_freeradius
RADIUS_LOG=/var/log/freeradius/radius.log
MONITOR_LOG=/var/log/check_backup_freeradius.log
STATE_DIR=/var/lib/check_backup_freeradius
LOCK_FILE=/var/run/check_backup_freeradius.lock
OFFSET_FILE="$STATE_DIR/radius.offset"
INODE_FILE="$STATE_DIR/radius.inode"
COOLDOWN_FILE="$STATE_DIR/last_successful_recovery"
MESSAGE_ID_FILE="$STATE_DIR/telegram_message_id"
INCIDENT_START_FILE="$STATE_DIR/incident_start"
INCIDENT_REASON_FILE="$STATE_DIR/incident_reason"

MKAUTH_NAME="$(hostname 2>/dev/null || printf mk-auth)"
USAR_TELEGRAM=nao
TELEGRAM_BOT=
TELEGRAM_CHAT_ID=
COOLDOWN_SECONDS=180
[ -r "$CONFIG" ] && . "$CONFIG"

mkdir -p "$STATE_DIR"
touch "$MONITOR_LOG"
exec 9>"$LOCK_FILE"
if ! command -v flock >/dev/null 2>&1; then
    printf '%s - ERRO: flock não está instalado.\n' "$(date '+%F %T')" >> "$MONITOR_LOG"
    exit 1
fi
flock -n 9 || exit 0

log() { printf '%s - %s\n' "$(date '+%F %T')" "$*" >> "$MONITOR_LOG"; }

detect_service() {
    local candidate
    for candidate in "$@"; do
        if [ -x "/etc/init.d/$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${candidate}.service" 2>/dev/null | grep -q "^${candidate}\.service"; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    printf '%s\n' "$1"
}

MYSQL_SERVICE="$(detect_service mysql mariadb mysqld)"
RADIUS_SERVICE="$(detect_service freeradius radiusd)"

service_action() {
    local name="$1" action="$2"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl "$action" "$name" && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service "$name" "$action" && return 0
    fi
    [ -x "/etc/init.d/$name" ] && "/etc/init.d/$name" "$action"
}

mysql_select() {
    if [ -r /etc/mysql/debian.cnf ]; then
        mysql --defaults-file=/etc/mysql/debian.cnf --connect-timeout=4 --batch --skip-column-names -e 'SELECT 1' 2>/dev/null
    elif [ -r /root/.my.cnf ]; then
        mysql --defaults-file=/root/.my.cnf --connect-timeout=4 --batch --skip-column-names -e 'SELECT 1' 2>/dev/null
    else
        mysql -uroot -pvertrigo --connect-timeout=4 --batch --skip-column-names -e 'SELECT 1' 2>/dev/null
    fi
}

mysql_ok() {
    local result
    command -v mysql >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        result="$(timeout 10 bash -c "$(declare -f mysql_select); mysql_select" 2>/dev/null)" || return 1
    else
        result="$(mysql_select)" || return 1
    fi
    [ "$result" = 1 ]
}

radius_process_ok() { pgrep -x freeradius >/dev/null 2>&1 || pgrep -x radiusd >/dev/null 2>&1; }
radius_port_ok() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lun 2>/dev/null | grep -Eq '[[:space:]](\[[^]]+\]|[^[:space:]]+):1812[[:space:]]'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lun 2>/dev/null | grep -Eq '[[:space:]](\[[^]]+\]|[^[:space:]]+):1812[[:space:]]'
    else
        log 'ERRO: ss e netstat não estão disponíveis para validar UDP 1812.'
        return 1
    fi
}
radius_ok() { radius_process_ok && radius_port_ok; }

wait_mysql() { local n=0; while [ "$n" -lt 60 ]; do mysql_ok && return 0; sleep 3; n=$((n+3)); done; return 1; }
wait_radius() { local n=0; while [ "$n" -lt 30 ]; do radius_ok && return 0; sleep 2; n=$((n+2)); done; return 1; }

telegram_enabled() { [ "$USAR_TELEGRAM" = sim ] && [ -n "$TELEGRAM_BOT" ] && [ -n "$TELEGRAM_CHAT_ID" ]; }
telegram_api() {
    local method="$1"; shift
    timeout 20 curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT}/${method}" "$@" 2>&1
}
telegram_send() {
    local text="$1" response id
    telegram_enabled || return 0
    response="$(telegram_api sendMessage --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text")"
    printf '%s' "$response" | grep -q '"ok":true' || { log "Falha no sendMessage: $(printf %.500s "$response")"; return 1; }
    id="$(printf '%s' "$response" | grep -o '"message_id":[0-9][0-9]*' | head -n1 | cut -d: -f2)"
    [ -n "$id" ] && printf '%s\n' "$id" > "$MESSAGE_ID_FILE"
}

event_details() {
    case "$1" in
        *"Can't connect to local MySQL server"*|*"Couldn't connect to MySQL server"*|*"rlm_sql_mysql: Couldn't connect"*) printf '%s|%s\n' '🔌' 'falha de conexão entre FreeRADIUS e MySQL' ;;
        *"Failed to reconnect"*|*"rlm_sql_mysql: MySQL error"*) printf '%s|%s\n' '🔄' 'falha de reconexão SQL' ;;
        *"no free connections are available"*) printf '%s|%s\n' '🚫' 'esgotamento de conexões SQL' ;;
        *"Something is blocking the server"*) printf '%s|%s\n' '🧱' 'bloqueio ou saturação do FreeRADIUS' ;;
        *"SELECT 1"*) printf '%s|%s\n' '🩺' 'MySQL sem resposta ao SELECT 1' ;;
        *) printf '%s|%s\n' '⚠️' 'falha desconhecida' ;;
    esac
}

format_duration() {
    local t="$1" h m s
    h=$((t/3600)); m=$(((t%3600)/60)); s=$((t%60))
    [ "$h" -gt 0 ] && { printf '%dh %dm %ds' "$h" "$m" "$s"; return; }
    [ "$m" -gt 0 ] && { printf '%dm %ds' "$m" "$s"; return; }
    printf '%ds' "$s"
}

send_alert() {
    local reason="$1" start alert_text
    start="$(date +%s)"
    printf '%s\n' "$start" > "$INCIDENT_START_FILE"
    printf '%s\n' "$reason" > "$INCIDENT_REASON_FILE"
    chmod 600 "$INCIDENT_START_FILE" "$INCIDENT_REASON_FILE"
    alert_text="$(printf '🚨 ALERTA MK-AUTH "%s"\n\nStatus: 🔴 PROBLEMA ATIVO\nMK-AUTH/VM: %s\nServidor Linux: %s\nErro completo detectado: %s\n🚨 Início do problema: %s' "$MKAUTH_NAME" "$MKAUTH_NAME" "$(hostname)" "$reason" "$(date '+%d/%m/%Y %H:%M:%S')")"
    telegram_send "$alert_text" || true
    [ -f "$MESSAGE_ID_FILE" ] && chmod 600 "$MESSAGE_ID_FILE"
}

resolved_message() {
    local reason="$1" start now duration detail emoji event mysql_state radius_state port_state
    start="$(cat "$INCIDENT_START_FILE" 2>/dev/null || date +%s)"
    now="$(date +%s)"; duration=$((now-start)); [ "$duration" -lt 0 ] && duration=0
    detail="$(event_details "$reason")"; emoji="${detail%%|*}"; event="${detail#*|}"
    mysql_ok && mysql_state='🟢 respondendo ao SELECT 1' || mysql_state='🔴 sem resposta ao SELECT 1'
    radius_process_ok && radius_state='🟢 processo ativo' || radius_state='🔴 processo inativo'
    radius_port_ok && port_state='🟢 ativa' || port_state='🔴 inativa'
    printf '✅ MK-AUTH RECUPERADO "%s"\n\nStatus: 🟢 INCIDENTE RESOLVIDO\nMK-AUTH/VM: %s\nServidor Linux: %s\nEvento: %s %s\nErro completo detectado: %s\n🚨 Início do problema: %s\n✅ Recuperado em: %s\n⏱️ Duração: %s\nEstado do MySQL: %s\nEstado do FreeRADIUS: %s\nPorta UDP 1812: %s' "$MKAUTH_NAME" "$MKAUTH_NAME" "$(hostname)" "$emoji" "$event" "$reason" "$(date -d "@$start" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || printf indisponível)" "$(date '+%d/%m/%Y %H:%M:%S')" "$(format_duration "$duration")" "$mysql_state" "$radius_state" "$port_state"
}

send_recovered() {
    local reason="$1" text response id
    telegram_enabled || return 0
    text="$(resolved_message "$reason")"; id="$(cat "$MESSAGE_ID_FILE" 2>/dev/null || true)"
    if [ -n "$id" ]; then
        response="$(telegram_api editMessageText --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "message_id=$id" --data-urlencode "text=$text")"
        printf '%s' "$response" | grep -q '"ok":true' && return 0
        log "Falha no editMessageText; usando sendMessage: $(printf %.500s "$response")"
    fi
    telegram_send "$text" || true
}

cooldown_active() {
    local last now
    [ -r "$COOLDOWN_FILE" ] || return 1
    read -r last < "$COOLDOWN_FILE"
    case "$last" in ''|*[!0-9]*) return 1;; esac
    now="$(date +%s)"
    [ $((now-last)) -ge 0 ] && [ $((now-last)) -lt "$COOLDOWN_SECONDS" ]
}

recover() {
    local reason="$1"
    log "Incidente detectado: $reason"
    rm -f "$MESSAGE_ID_FILE" "$INCIDENT_START_FILE" "$INCIDENT_REASON_FILE"
    send_alert "$reason"
    service_action "$RADIUS_SERVICE" stop >> "$MONITOR_LOG" 2>&1 || true
    if ! service_action "$MYSQL_SERVICE" restart >> "$MONITOR_LOG" 2>&1; then log "ERRO: falha ao reiniciar $MYSQL_SERVICE"; service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true; return 1; fi
    if ! wait_mysql; then log 'ERRO: MySQL não respondeu ao SELECT 1 em 60 segundos.'; service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true; return 1; fi
    if ! service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1; then log "ERRO: falha ao iniciar $RADIUS_SERVICE"; return 1; fi
    if ! wait_radius; then log 'ERRO: processo/porta UDP 1812 do FreeRADIUS não confirmado.'; return 1; fi
    date +%s > "$COOLDOWN_FILE"; chmod 600 "$COOLDOWN_FILE"
    send_recovered "$reason"
    rm -f "$MESSAGE_ID_FILE" "$INCIDENT_START_FILE" "$INCIDENT_REASON_FILE"
    log "Recuperação concluída; cooldown de $COOLDOWN_SECONDS segundos."
}

read_new_log() {
    local inode size old_inode= old_offset=0 start
    FOUND_LINE=
    [ -f "$RADIUS_LOG" ] || { log "AVISO: $RADIUS_LOG não encontrado."; return; }
    inode="$(stat -c %i "$RADIUS_LOG" 2>/dev/null)" || return
    size="$(stat -c %s "$RADIUS_LOG" 2>/dev/null)" || return
    [ -r "$INODE_FILE" ] && read -r old_inode < "$INODE_FILE"
    [ -r "$OFFSET_FILE" ] && read -r old_offset < "$OFFSET_FILE"
    case "$old_offset" in ''|*[!0-9]*) old_offset=0;; esac
    if [ ! -f "$OFFSET_FILE" ]; then old_offset="$size"; elif [ "$inode" != "$old_inode" ] || [ "$size" -lt "$old_offset" ]; then old_offset=0; fi
    if [ "$size" -gt "$old_offset" ]; then
        start=$((old_offset+1))
        FOUND_LINE="$(tail -c +"$start" "$RADIUS_LOG" 2>/dev/null | grep -F -m1 -e "MySQL error: Can't connect to local MySQL server through socket" -e "Can't connect to local MySQL server through socket" -e "Couldn't connect to MySQL server" -e 'Failed to reconnect' -e 'no free connections are available' -e "rlm_sql_mysql: Couldn't connect" -e 'rlm_sql_mysql: MySQL error' -e 'Error: Something is blocking the server.' || true)"
    fi
    printf '%s\n' "$inode" > "$INODE_FILE"; printf '%s\n' "$size" > "$OFFSET_FILE"
}

FOUND_LINE=
read_new_log
if ! mysql_ok; then recover "${FOUND_LINE:-MySQL não respondeu ao comando SELECT 1.}"; exit $?; fi
if [ -n "$FOUND_LINE" ]; then
    if cooldown_active; then log "Evento ignorado durante cooldown (SELECT 1 está normal): $FOUND_LINE"; exit 0; fi
    recover "$FOUND_LINE"; exit $?
fi
exit 0
