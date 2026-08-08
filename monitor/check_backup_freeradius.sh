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
FAIL_START_FILE="$STATE_DIR/mysql_fail_start"

MKAUTH_NAME="$(hostname 2>/dev/null || printf mk-auth)"
USAR_TELEGRAM=nao
TELEGRAM_BOT=
TELEGRAM_CHAT_ID=
COOLDOWN_SECONDS=180
WAIT_AUTO_RECOVERY=90
MYSQL_START_TIMEOUT=150

if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

mkdir -p "$STATE_DIR"
touch "$MONITOR_LOG"

exec 9>"$LOCK_FILE"
if ! command -v flock >/dev/null 2>&1; then
    printf '%s - ERRO: flock não está instalado.\n' "$(date '+%F %T')" >> "$MONITOR_LOG"
    exit 1
fi
flock -n 9 || exit 0

log() {
    printf '%s - %s\n' "$(date '+%F %T')" "$*" >> "$MONITOR_LOG"
}

compact_response() {
    printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-500
}

detect_service() {
    local candidate
    for candidate in "$@"; do
        if [ -x "/etc/init.d/$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if command -v systemctl >/dev/null 2>&1 &&
           systemctl list-unit-files "${candidate}.service" 2>/dev/null |
           grep -q "^${candidate}\.service"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '%s\n' "$1"
}

MYSQL_SERVICE="$(detect_service mysql mariadb mysqld)"
RADIUS_SERVICE="$(detect_service freeradius radiusd)"
MYSQL_CLIENT="$(command -v mysql 2>/dev/null || command -v mariadb 2>/dev/null || true)"

service_action() {
    local name="$1" action="$2"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl "$action" "$name" && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service "$name" "$action" && return 0
    fi
    if [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" "$action" && return 0
    fi
    return 1
}

mysql_select() {
    [ -n "$MYSQL_CLIENT" ] || return 1
    if [ -r /etc/mysql/debian.cnf ]; then
        timeout 10 "$MYSQL_CLIENT" --defaults-file=/etc/mysql/debian.cnf --connect-timeout=4 --batch --skip-column-names -e 'SELECT 1' 2>/dev/null
    elif [ -r /root/.my.cnf ]; then
        timeout 10 "$MYSQL_CLIENT" --defaults-file=/root/.my.cnf --connect-timeout=4 --batch --skip-column-names -e 'SELECT 1' 2>/dev/null
    else
        timeout 10 "$MYSQL_CLIENT" -uroot -pvertrigo --connect-timeout=4 --batch --skip-column-names -e 'SELECT 1' 2>/dev/null
    fi
}

mysql_ok() {
    local result
    result="$(mysql_select)" || return 1
    [ "$result" = 1 ]
}

radius_process_ok() {
    pgrep -x freeradius >/dev/null 2>&1 || pgrep -x radiusd >/dev/null 2>&1
}

radius_port_ok() {
    if command -v ss >/dev/null 2>&1; then
        if ss -H -lun 'sport = :1812' 2>/dev/null | grep -q .; then
            return 0
        fi
        ss -H -lun 2>/dev/null |
            grep -Eq '(^|[[:space:]])(\[[^]]+\]|[^[:space:]]+):1812([[:space:]]|$)'
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lun 2>/dev/null |
            grep -Eq '(^|[[:space:]])(\[[^]]+\]|[^[:space:]]+):1812([[:space:]]|$)'
        return $?
    fi
    log 'ERRO: ss e netstat não estão disponíveis para validar UDP 1812.'
    return 1
}

radius_ok() {
    radius_process_ok && radius_port_ok
}

wait_mysql() {
    local limit="${1:-60}" elapsed=0
    while [ "$elapsed" -lt "$limit" ]; do
        mysql_ok && return 0
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

wait_radius() {
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        radius_ok && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

telegram_enabled() {
    [ "$USAR_TELEGRAM" = sim ] && [ -n "$TELEGRAM_BOT" ] && [ -n "$TELEGRAM_CHAT_ID" ]
}

telegram_api() {
    local method="$1"
    shift
    timeout 20 curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT}/${method}" "$@" 2>&1
}

telegram_send_plain() {
    local text="$1" response
    telegram_enabled || return 0
    response="$(telegram_api sendMessage --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text")"
    if printf '%s' "$response" | grep -q '"ok":true'; then
        return 0
    fi
    log "Falha no sendMessage: $(compact_response "$response")"
    return 1
}

event_details() {
    case "$1" in
        *"Can't connect to local MySQL server"*|*"Couldn't connect to MySQL server"*|*"rlm_sql_mysql: Couldn't connect"*)
            printf '%s|%s\n' '🔌' 'falha de conexão entre FreeRADIUS e MySQL' ;;
        *"Failed to reconnect"*|*"rlm_sql_mysql: MySQL error"*)
            printf '%s|%s\n' '🔄' 'falha de reconexão SQL' ;;
        *"no free connections are available"*)
            printf '%s|%s\n' '🚫' 'esgotamento de conexões SQL' ;;
        *"Something is blocking the server"*)
            printf '%s|%s\n' '🧱' 'bloqueio ou saturação do FreeRADIUS' ;;
        *"SELECT 1"*)
            printf '%s|%s\n' '🩺' 'MySQL sem resposta ao SELECT 1' ;;
        *)
            printf '%s|%s\n' '⚠️' 'falha desconhecida' ;;
    esac
}

format_duration() {
    local total="$1" hours minutes seconds
    case "$total" in ''|*[!0-9]*) total=0;; esac
    hours=$((total / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))
    if [ "$hours" -gt 0 ]; then
        printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm %ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

clear_incident_state() {
    rm -f "$MESSAGE_ID_FILE" "$INCIDENT_START_FILE" "$INCIDENT_REASON_FILE"
}

send_alert() {
    local reason="$1" start text response message_id
    start="$(date +%s)"
    printf '%s\n' "$start" > "$INCIDENT_START_FILE"
    printf '%s\n' "$reason" > "$INCIDENT_REASON_FILE"
    chmod 600 "$INCIDENT_START_FILE" "$INCIDENT_REASON_FILE"
    telegram_enabled || return 0
    text="$(printf '🚨 ALERTA MK-AUTH "%s"\n\nStatus: 🔴 PROBLEMA ATIVO\nMK-AUTH/VM: %s\nServidor Linux: %s\nErro completo detectado: %s\n🚨 Início do problema: %s\n\nA recuperação automática foi iniciada.' "$MKAUTH_NAME" "$MKAUTH_NAME" "$(hostname)" "$reason" "$(date '+%d/%m/%Y %H:%M:%S')")"
    response="$(telegram_api sendMessage --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text")"
    message_id="$(printf '%s' "$response" | grep -o '"message_id":[0-9][0-9]*' | head -n1 | cut -d: -f2)"
    if printf '%s' "$response" | grep -q '"ok":true' && [ -n "$message_id" ]; then
        printf '%s\n' "$message_id" > "$MESSAGE_ID_FILE"
        chmod 600 "$MESSAGE_ID_FILE"
        log "Alerta enviado ao Telegram. message_id=$message_id"
        return 0
    fi
    log "Falha ao enviar alerta: $(compact_response "$response")"
    return 1
}

resolved_message() {
    local reason="$1" start now duration detail emoji event mysql_state radius_state port_state start_text
    start="$(cat "$INCIDENT_START_FILE" 2>/dev/null || date +%s)"
    case "$start" in ''|*[!0-9]*) start="$(date +%s)";; esac
    now="$(date +%s)"
    duration=$((now - start))
    [ "$duration" -lt 0 ] && duration=0
    detail="$(event_details "$reason")"
    emoji="${detail%%|*}"
    event="${detail#*|}"
    mysql_ok && mysql_state='🟢 respondendo ao SELECT 1' || mysql_state='🔴 sem resposta ao SELECT 1'
    radius_process_ok && radius_state='🟢 processo ativo' || radius_state='🔴 processo inativo'
    radius_port_ok && port_state='🟢 ativa' || port_state='🔴 inativa'
    start_text="$(date -d "@$start" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || printf indisponível)"
    printf '✅ MK-AUTH RECUPERADO "%s"\n\nStatus: 🟢 INCIDENTE RESOLVIDO\nMK-AUTH/VM: %s\nServidor Linux: %s\nEvento: %s %s\nErro completo detectado: %s\n🚨 Início do problema: %s\n✅ Recuperado em: %s\n⏱️ Duração: %s\nEstado do MySQL: %s\nEstado do FreeRADIUS: %s\nPorta UDP 1812: %s' "$MKAUTH_NAME" "$MKAUTH_NAME" "$(hostname)" "$emoji" "$event" "$reason" "$start_text" "$(date '+%d/%m/%Y %H:%M:%S')" "$(format_duration "$duration")" "$mysql_state" "$radius_state" "$port_state"
}

send_recovered() {
    local reason="$1" text response message_id
    telegram_enabled || return 0
    text="$(resolved_message "$reason")"
    message_id="$(cat "$MESSAGE_ID_FILE" 2>/dev/null || true)"
    case "$message_id" in ''|*[!0-9]*) message_id=;; esac
    if [ -n "$message_id" ]; then
        response="$(telegram_api editMessageText --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "message_id=$message_id" --data-urlencode "text=$text")"
        if printf '%s' "$response" | grep -q '"ok":true'; then
            log 'Mensagem original editada como recuperada.'
            return 0
        fi
        log "Falha no editMessageText; usando sendMessage: $(compact_response "$response")"
    fi
    telegram_send_plain "$text"
}

cooldown_active() {
    local last now difference
    [ -r "$COOLDOWN_FILE" ] || return 1
    read -r last < "$COOLDOWN_FILE"
    case "$last" in ''|*[!0-9]*) return 1;; esac
    case "$COOLDOWN_SECONDS" in ''|*[!0-9]*) COOLDOWN_SECONDS=180;; esac
    now="$(date +%s)"
    difference=$((now - last))
    [ "$difference" -ge 0 ] && [ "$difference" -lt "$COOLDOWN_SECONDS" ]
}

mark_recovery() {
    date +%s > "$COOLDOWN_FILE"
    chmod 600 "$COOLDOWN_FILE"
}

restart_radius() {
    log "Reiniciando $RADIUS_SERVICE."
    service_action "$RADIUS_SERVICE" restart >> "$MONITOR_LOG" 2>&1 ||
        service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true
    wait_radius
}

recover_standard() {
    local reason="$1"
    log '======================================================'
    log "Incidente detectado em $MKAUTH_NAME: $reason"
    log "Serviços detectados: banco=$MYSQL_SERVICE radius=$RADIUS_SERVICE"
    clear_incident_state
    send_alert "$reason" || true

    log "Parando $RADIUS_SERVICE."
    service_action "$RADIUS_SERVICE" stop >> "$MONITOR_LOG" 2>&1 || true

    log "Reiniciando $MYSQL_SERVICE."
    if ! service_action "$MYSQL_SERVICE" restart >> "$MONITOR_LOG" 2>&1; then
        log "ERRO: não foi possível reiniciar $MYSQL_SERVICE."
        service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true
        telegram_send_plain "❌ MYSQL NÃO RECUPERADO \"$MKAUTH_NAME\"\n\nFalha ao reiniciar $MYSQL_SERVICE em $(hostname)." || true
        return 1
    fi

    if ! wait_mysql; then
        log 'ERRO: MySQL/MariaDB não respondeu ao SELECT 1 em 60 segundos.'
        service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true
        telegram_send_plain "❌ MYSQL NÃO RECUPERADO \"$MKAUTH_NAME\"\n\nO banco não respondeu ao SELECT 1 em 60 segundos." || true
        return 1
    fi

    log "Iniciando $RADIUS_SERVICE."
    if ! service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1; then
        log "ERRO: não foi possível iniciar $RADIUS_SERVICE."
        telegram_send_plain "❌ FREERADIUS NÃO INICIOU \"$MKAUTH_NAME\"\n\nO banco voltou, mas $RADIUS_SERVICE não iniciou." || true
        return 1
    fi

    if ! wait_radius; then
        log 'ERRO: processo e porta UDP 1812 do FreeRADIUS não foram confirmados.'
        telegram_send_plain "⚠️ RECUPERAÇÃO PARCIAL \"$MKAUTH_NAME\"\n\nMySQL: respondendo\nFreeRADIUS/UDP 1812: não confirmado" || true
        return 1
    fi

    mark_recovery
    send_recovered "$reason" || true
    clear_incident_state
    log "Recuperação concluída; cooldown de $COOLDOWN_SECONDS segundos."
    log '======================================================'
    return 0
}

recover_controlled() {
    local reason="$1" mysql_processes
    log '======================================================'
    log "Falha persistente em $MKAUTH_NAME: $reason"
    log "Iniciando recuperação controlada após ${WAIT_AUTO_RECOVERY}s."

    service_action "$RADIUS_SERVICE" stop >> "$MONITOR_LOG" 2>&1 || true
    service_action "$MYSQL_SERVICE" stop >> "$MONITOR_LOG" 2>&1 || true
    sleep 8

    pkill -TERM mysqld 2>/dev/null || true
    pkill -TERM mariadbd 2>/dev/null || true
    sleep 10

    if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then
        mysql_processes="$(pgrep -af 'mysqld|mariadbd' 2>/dev/null | tr '\n' ' ')"
        log "Processo do banco permaneceu preso: $mysql_processes"
        log 'Aplicando KILL somente após TERM e espera controlada.'
        pkill -KILL mysqld 2>/dev/null || true
        pkill -KILL mariadbd 2>/dev/null || true
        sleep 4
    fi

    if ! pgrep -x mysqld >/dev/null 2>&1 && ! pgrep -x mariadbd >/dev/null 2>&1; then
        rm -f /var/run/mysqld/mysqld.sock /var/run/mysqld/mysqld.pid
        rm -f /run/mysqld/mysqld.sock /run/mysqld/mysqld.pid
        mkdir -p /var/run/mysqld
        if id mysql >/dev/null 2>&1; then
            chown mysql:mysql /var/run/mysqld
        fi
        chmod 755 /var/run/mysqld
    fi

    service_action "$MYSQL_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true
    if ! wait_mysql "$MYSQL_START_TIMEOUT"; then
        log "CRÍTICO: banco não respondeu em ${MYSQL_START_TIMEOUT}s."
        telegram_send_plain "❌ MYSQL NÃO RECUPERADO \"$MKAUTH_NAME\"\n\nA recuperação controlada não restabeleceu o SELECT 1." || true
        return 1
    fi

    service_action "$RADIUS_SERVICE" start >> "$MONITOR_LOG" 2>&1 || true
    if ! wait_radius; then
        service_action "$RADIUS_SERVICE" restart >> "$MONITOR_LOG" 2>&1 || true
        if ! wait_radius; then
            log 'CRÍTICO: FreeRADIUS/UDP 1812 não recuperou.'
            return 1
        fi
    fi

    rm -f "$FAIL_START_FILE"
    mark_recovery
    send_recovered "$reason" || true
    clear_incident_state
    log 'Recuperação controlada concluída.'
    log '======================================================'
    return 0
}

read_new_log() {
    local inode size old_inode= old_offset=0 start new_data
    FOUND_LINE=
    if [ ! -f "$RADIUS_LOG" ]; then
        log "AVISO: $RADIUS_LOG não encontrado."
        return 0
    fi
    inode="$(stat -c %i "$RADIUS_LOG" 2>/dev/null)" || return 0
    size="$(stat -c %s "$RADIUS_LOG" 2>/dev/null)" || return 0
    [ -r "$INODE_FILE" ] && read -r old_inode < "$INODE_FILE"
    [ -r "$OFFSET_FILE" ] && read -r old_offset < "$OFFSET_FILE"
    case "$old_offset" in ''|*[!0-9]*) old_offset=0;; esac

    if [ ! -f "$OFFSET_FILE" ]; then
        old_offset="$size"
        log "Monitor iniciado em $MKAUTH_NAME; offset inicial=$size."
    elif [ "$inode" != "$old_inode" ] || [ "$size" -lt "$old_offset" ]; then
        old_offset=0
        log 'Rotação/truncamento do radius.log detectado; offset reiniciado.'
    fi

    if [ "$size" -gt "$old_offset" ]; then
        start=$((old_offset + 1))
        new_data="$(tail -c +"$start" "$RADIUS_LOG" 2>/dev/null || true)"
        FOUND_LINE="$(printf '%s\n' "$new_data" | grep -F -m1 \
            -e "MySQL error: Can't connect to local MySQL server through socket" \
            -e "Can't connect to local MySQL server through socket" \
            -e "Couldn't connect to MySQL server" \
            -e 'Failed to reconnect' \
            -e 'no free connections are available' \
            -e "rlm_sql_mysql: Couldn't connect" \
            -e 'rlm_sql_mysql: MySQL error' \
            -e 'Error: Something is blocking the server.' || true)"
    fi

    printf '%s\n' "$inode" > "${INODE_FILE}.tmp"
    printf '%s\n' "$size" > "${OFFSET_FILE}.tmp"
    mv -f "${INODE_FILE}.tmp" "$INODE_FILE"
    mv -f "${OFFSET_FILE}.tmp" "$OFFSET_FILE"
    chmod 600 "$INODE_FILE" "$OFFSET_FILE"
}

FOUND_LINE=
read_new_log

NOW="$(date +%s)"

if mysql_ok; then
    if [ -r "$FAIL_START_FILE" ]; then
        read -r FAIL_START < "$FAIL_START_FILE"
        case "$FAIL_START" in ''|*[!0-9]*) FAIL_START="$NOW";; esac
        REASON="$(cat "$INCIDENT_REASON_FILE" 2>/dev/null || printf 'MySQL não respondeu ao comando SELECT 1.')"
        log "Banco voltou automaticamente após $((NOW - FAIL_START))s; reiniciando FreeRADIUS para limpar o pool SQL."
        if restart_radius; then
            rm -f "$FAIL_START_FILE"
            mark_recovery
            send_recovered "$REASON" || true
            clear_incident_state
            exit 0
        fi
        log 'CRÍTICO: banco voltou, mas FreeRADIUS/UDP 1812 não recuperou.'
        exit 1
    fi

    if [ -n "$FOUND_LINE" ]; then
        if cooldown_active; then
            log "Evento ignorado durante cooldown porque SELECT 1 está normal: $FOUND_LINE"
            exit 0
        fi
        recover_standard "$FOUND_LINE"
        exit $?
    fi

    if ! radius_ok; then
        if cooldown_active; then
            log 'MySQL normal, mas FreeRADIUS/UDP 1812 inativo durante cooldown.'
            exit 0
        fi
        clear_incident_state
        send_alert 'MySQL responde normalmente, porém o FreeRADIUS ou a porta UDP 1812 estão inativos.' || true
        if restart_radius; then
            mark_recovery
            send_recovered 'FreeRADIUS ou porta UDP 1812 estavam inativos.' || true
            clear_incident_state
            exit 0
        fi
        exit 1
    fi

    exit 0
fi

REASON="${FOUND_LINE:-MySQL não respondeu ao comando SELECT 1.}"

if [ ! -r "$FAIL_START_FILE" ]; then
    printf '%s\n' "$NOW" > "$FAIL_START_FILE"
    chmod 600 "$FAIL_START_FILE"
    clear_incident_state
    send_alert "$REASON" || true
    log "Banco indisponível; aguardando recuperação automática por ${WAIT_AUTO_RECOVERY}s."
    exit 0
fi

read -r FAIL_START < "$FAIL_START_FILE"
case "$FAIL_START" in
    ''|*[!0-9]*) FAIL_START="$NOW"; printf '%s\n' "$NOW" > "$FAIL_START_FILE";;
esac
FAIL_DURATION=$((NOW - FAIL_START))

if [ "$FAIL_DURATION" -lt "$WAIT_AUTO_RECOVERY" ]; then
    log "Banco indisponível há ${FAIL_DURATION}s; aguardando recuperação automática."
    exit 0
fi

# Falha real no SELECT 1 ignora o cooldown.
recover_controlled "$REASON"
exit $?
