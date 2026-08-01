cat > /root/instalar-monitor-mkauth.sh <<'INSTALADOR'
#!/bin/bash

set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT="/var/check_backup_freeradius.sh"
CONFIG="/etc/default/check_backup_freeradius"
CRON_FILE="/etc/cron.d/check_backup_freeradius"

MONITOR_LOG="/var/log/check_backup_freeradius.log"
CRON_LOG="/var/log/check_backup_freeradius_cron.log"

STATE_DIR="/var/lib/check_backup_freeradius"
LOGROTATE="/etc/logrotate.d/check_backup_freeradius"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERRO: execute este instalador como root."
    exit 1
fi

echo
echo "=========================================================="
echo " INSTALAÇÃO DO MONITOR MK-AUTH - MYSQL + FREERADIUS"
echo "=========================================================="
echo

HOSTNAME_ATUAL="$(hostname 2>/dev/null || echo mk-auth)"

printf "Nome deste MK-AUTH/VM [%s]: " "$HOSTNAME_ATUAL"
read -r MKAUTH_NAME

if [ -z "$MKAUTH_NAME" ]; then
    MKAUTH_NAME="$HOSTNAME_ATUAL"
fi

echo
printf "Deseja utilizar o envio de alertas pelo Telegram? [S/n]: "
read -r USAR_TELEGRAM

case "$USAR_TELEGRAM" in
    n|N|nao|NAO|não|NÃO)
        USAR_TELEGRAM="nao"
        TELEGRAM_BOT=""
        TELEGRAM_CHAT_ID=""

        echo
        echo "Envio para o Telegram desativado."
        ;;

    *)
        USAR_TELEGRAM="sim"

        echo
        printf "Token do bot Telegram: "
        read -r TELEGRAM_BOT

        while [ -z "$TELEGRAM_BOT" ]; do
            echo "O token não pode ficar vazio."
            printf "Token do bot Telegram: "
            read -r TELEGRAM_BOT
        done

        CHAT_PADRAO="-5546953464"

        printf "Chat ID do grupo Telegram [%s]: " "$CHAT_PADRAO"
        read -r TELEGRAM_CHAT_ID

        if [ -z "$TELEGRAM_CHAT_ID" ]; then
            TELEGRAM_CHAT_ID="$CHAT_PADRAO"
        fi

        echo
        echo "Envio para o Telegram ativado."
        ;;
esac

echo
echo "MK-AUTH: $MKAUTH_NAME"

if [ "$USAR_TELEGRAM" = "sim" ]; then
    echo "Chat ID: $TELEGRAM_CHAT_ID"
fi

echo

# ==========================================================
# BACKUPS
# ==========================================================

for ITEM in "$SCRIPT" "$CONFIG" "$CRON_FILE" "$LOGROTATE"; do
    if [ -e "$ITEM" ]; then
        cp -a "$ITEM" "${ITEM}.bak-${TIMESTAMP}"
        echo "Backup criado: ${ITEM}.bak-${TIMESTAMP}"
    fi
done

# ==========================================================
# DESATIVAR CRONS ANTIGOS
# ==========================================================

echo
echo "Procurando crons antigos..."

CRON_FILES="$(
    {
        [ -f /etc/crontab ] && echo /etc/crontab

        find /etc/cron.d \
            -maxdepth 1 \
            -type f \
            2>/dev/null

        find /var/spool/cron \
            /var/spool/cron/crontabs \
            -maxdepth 2 \
            -type f \
            2>/dev/null
    } | sort -u
)"

while IFS= read -r FILE; do
    [ -n "$FILE" ] || continue
    [ -f "$FILE" ] || continue

    # O cron definitivo será recriado depois.
    if [ "$FILE" = "$CRON_FILE" ]; then
        continue
    fi

    if grep -Eq \
        '^[[:space:]]*[^#].*check_backup_freeradius\.sh' \
        "$FILE" 2>/dev/null; then

        cp -a "$FILE" "${FILE}.bak-${TIMESTAMP}"

        sed -i \
            "/^[[:space:]]*[^#].*check_backup_freeradius\.sh/s|^|# DESATIVADO ${TIMESTAMP}: |" \
            "$FILE"

        echo "Cron antigo desativado em: $FILE"
    fi
done <<EOF
$CRON_FILES
EOF

# ==========================================================
# CONFIGURAÇÃO
# ==========================================================

{
    printf 'MKAUTH_NAME=%q\n' "$MKAUTH_NAME"
    printf 'USAR_TELEGRAM=%q\n' "$USAR_TELEGRAM"
    printf 'TELEGRAM_BOT=%q\n' "$TELEGRAM_BOT"
    printf 'TELEGRAM_CHAT_ID=%q\n' "$TELEGRAM_CHAT_ID"
    printf 'COOLDOWN_SECONDS=%q\n' "180"
} > "$CONFIG"

chown root:root "$CONFIG"
chmod 600 "$CONFIG"

# ==========================================================
# DIRETÓRIOS E LOGS
# ==========================================================

mkdir -p "$STATE_DIR"

touch "$MONITOR_LOG"
touch "$CRON_LOG"

chown root:root \
    "$STATE_DIR" \
    "$MONITOR_LOG" \
    "$CRON_LOG"

chmod 750 "$STATE_DIR"
chmod 640 "$MONITOR_LOG" "$CRON_LOG"

# ==========================================================
# CRIAR MONITOR
# ==========================================================

cat > "$SCRIPT" <<'MONITOR'
#!/bin/bash

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG="/etc/default/check_backup_freeradius"

RADIUS_LOG="/var/log/freeradius/radius.log"
MONITOR_LOG="/var/log/check_backup_freeradius.log"

STATE_DIR="/var/lib/check_backup_freeradius"

OFFSET_FILE="$STATE_DIR/radius.offset"
INODE_FILE="$STATE_DIR/radius.inode"
COOLDOWN_FILE="$STATE_DIR/last_successful_recovery"

MESSAGE_ID_FILE="$STATE_DIR/telegram_message_id"
INCIDENT_START_FILE="$STATE_DIR/incident_start"
INCIDENT_REASON_FILE="$STATE_DIR/incident_reason"

LOCK_FILE="/var/run/check_backup_freeradius.lock"

MKAUTH_NAME="$(hostname)"
USAR_TELEGRAM="nao"
TELEGRAM_BOT=""
TELEGRAM_CHAT_ID=""
COOLDOWN_SECONDS="180"

if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

PHRASES=(
    "MySQL error: Can't connect to local MySQL server through socket"
    "Can't connect to local MySQL server through socket"
    "Couldn't connect to MySQL server"
    "Failed to reconnect"
    "no free connections are available"
    "rlm_sql_mysql: Couldn't connect"
    "rlm_sql_mysql: MySQL error"
    "Error: Something is blocking the server."
)

mkdir -p "$STATE_DIR"
touch "$MONITOR_LOG"

exec 9>"$LOCK_FILE"

if command -v flock >/dev/null 2>&1; then
    flock -n 9 || exit 0
fi

log() {
    printf '%s - %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >> "$MONITOR_LOG"
}

compact_response() {
    printf '%s' "$1" |
        tr '\r\n' '  ' |
        cut -c1-500
}

detect_mysql_service() {
    local name=""

    for name in mysql mariadb mysqld; do
        if [ -x "/etc/init.d/$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi

        if command -v systemctl >/dev/null 2>&1 &&
           systemctl list-unit-files 2>/dev/null |
           grep -q "^${name}\.service"; then

            printf '%s\n' "$name"
            return 0
        fi
    done

    printf '%s\n' "mysql"
}

detect_radius_service() {
    local name=""

    for name in freeradius radiusd; do
        if [ -x "/etc/init.d/$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi

        if command -v systemctl >/dev/null 2>&1 &&
           systemctl list-unit-files 2>/dev/null |
           grep -q "^${name}\.service"; then

            printf '%s\n' "$name"
            return 0
        fi
    done

    printf '%s\n' "freeradius"
}

MYSQL_SERVICE="$(detect_mysql_service)"
RADIUS_SERVICE="$(detect_radius_service)"

service_action() {
    local service_name="$1"
    local action="$2"

    if command -v systemctl >/dev/null 2>&1 &&
       [ -d /run/systemd/system ]; then

        systemctl "$action" "$service_name"
        return $?
    fi

    if command -v service >/dev/null 2>&1; then
        service "$service_name" "$action"
        return $?
    fi

    if [ -x "/etc/init.d/$service_name" ]; then
        "/etc/init.d/$service_name" "$action"
        return $?
    fi

    return 1
}

mysql_query() {
    if [ -r /etc/mysql/debian.cnf ]; then
        mysql \
            --defaults-file=/etc/mysql/debian.cnf \
            --connect-timeout=4 \
            --batch \
            --skip-column-names \
            -e "SELECT 1" 2>/dev/null
        return $?
    fi

    if [ -r /root/.my.cnf ]; then
        mysql \
            --defaults-file=/root/.my.cnf \
            --connect-timeout=4 \
            --batch \
            --skip-column-names \
            -e "SELECT 1" 2>/dev/null
        return $?
    fi

    mysql \
        -uroot \
        -pvertrigo \
        --connect-timeout=4 \
        --batch \
        --skip-column-names \
        -e "SELECT 1" 2>/dev/null
}

mysql_ok() {
    local result=""

    command -v mysql >/dev/null 2>&1 || return 1

    if command -v timeout >/dev/null 2>&1; then
        result="$(
            timeout 10 bash -c '
                if [ -r /etc/mysql/debian.cnf ]; then
                    mysql \
                        --defaults-file=/etc/mysql/debian.cnf \
                        --connect-timeout=4 \
                        --batch \
                        --skip-column-names \
                        -e "SELECT 1" 2>/dev/null
                elif [ -r /root/.my.cnf ]; then
                    mysql \
                        --defaults-file=/root/.my.cnf \
                        --connect-timeout=4 \
                        --batch \
                        --skip-column-names \
                        -e "SELECT 1" 2>/dev/null
                else
                    mysql \
                        -uroot \
                        -pvertrigo \
                        --connect-timeout=4 \
                        --batch \
                        --skip-column-names \
                        -e "SELECT 1" 2>/dev/null
                fi
            ' 2>/dev/null
        )"
    else
        result="$(mysql_query)"
    fi

    [ "$result" = "1" ]
}

radius_process_ok() {
    pgrep -x freeradius >/dev/null 2>&1 ||
    pgrep -x radiusd >/dev/null 2>&1
}

radius_port_ok() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lun 2>/dev/null |
            awk '{print $4}' |
            grep -Eq ':1812$'

        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -lun 2>/dev/null |
            awk '{print $4}' |
            grep -Eq ':1812$'

        return $?
    fi

    # A ausência de ss/netstat não bloqueia a recuperação.
    return 0
}

radius_ok() {
    radius_process_ok && radius_port_ok
}

wait_mysql() {
    local elapsed=0

    while [ "$elapsed" -lt 60 ]; do
        if mysql_ok; then
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    return 1
}

wait_radius() {
    local elapsed=0

    while [ "$elapsed" -lt 30 ]; do
        if radius_ok; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

telegram_configured() {
    [ "$USAR_TELEGRAM" = "sim" ] &&
    [ -n "$TELEGRAM_BOT" ] &&
    [ -n "$TELEGRAM_CHAT_ID" ]
}

send_plain_telegram() {
    local message="$1"
    local response=""

    telegram_configured || return 0

    response="$(
        timeout 20 curl -sS \
            -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT}/sendMessage" \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=$message" \
            2>&1
    )"

    if printf '%s' "$response" |
       grep -q '"ok":true'; then

        log "Mensagem enviada ao Telegram com sucesso."
        return 0
    fi

    log "ERRO Telegram: $(compact_response "$response")"
    return 1
}

clear_incident_state() {
    rm -f \
        "$MESSAGE_ID_FILE" \
        "$INCIDENT_START_FILE" \
        "$INCIDENT_REASON_FILE"
}

send_incident_alert() {
    local reason="$1"
    local response=""
    local message_id=""
    local start_epoch=""

    telegram_configured || return 0

    start_epoch="$(date +%s)"

    response="$(
        timeout 20 curl -sS \
            -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT}/sendMessage" \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=🚨 ALERTA MK-AUTH \"$MKAUTH_NAME\"

Status: 🔴 PROBLEMA ATIVO

MK-AUTH/VM: $MKAUTH_NAME
Servidor Linux: $(hostname)

📝 Erro detectado:
$reason

🚨 Início do problema:
$(date '+%d/%m/%Y %H:%M:%S')

A recuperação automática do MySQL e FreeRADIUS foi iniciada." \
            2>&1
    )"

    message_id="$(
        printf '%s' "$response" |
            grep -o '"message_id":[0-9][0-9]*' |
            head -n 1 |
            cut -d: -f2
    )"

    if printf '%s' "$response" |
       grep -q '"ok":true' &&
       [ -n "$message_id" ]; then

        printf '%s\n' "$message_id" > "$MESSAGE_ID_FILE"
        printf '%s\n' "$start_epoch" > "$INCIDENT_START_FILE"
        printf '%s\n' "$reason" > "$INCIDENT_REASON_FILE"

        chmod 600 \
            "$MESSAGE_ID_FILE" \
            "$INCIDENT_START_FILE" \
            "$INCIDENT_REASON_FILE"

        log "Alerta enviado ao Telegram. message_id=$message_id"
        return 0
    fi

    log "ERRO ao enviar alerta: $(compact_response "$response")"
    return 1
}

format_duration() {
    local total="$1"
    local hours=0
    local minutes=0
    local seconds=0

    case "$total" in
        ''|*[!0-9]*)
            total=0
            ;;
    esac

    hours=$((total / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))

    if [ "$hours" -gt 0 ]; then
        printf '%dh %dm %ds' \
            "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm %ds' \
            "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

edit_incident_as_recovered() {
    local message_id=""
    local incident_start=""
    local reason=""
    local recovered_epoch=""
    local duration_seconds=""
    local duration_text=""
    local start_text=""
    local recovered_text=""
    local event_emoji=""
    local event_name=""
    local response=""

    telegram_configured || return 0

    [ -r "$MESSAGE_ID_FILE" ] || return 1
    [ -r "$INCIDENT_START_FILE" ] || return 1

    read -r message_id < "$MESSAGE_ID_FILE"
    read -r incident_start < "$INCIDENT_START_FILE"

    if [ -r "$INCIDENT_REASON_FILE" ]; then
        reason="$(cat "$INCIDENT_REASON_FILE")"
    else
        reason="Erro de comunicação entre MySQL e FreeRADIUS."
    fi

    case "$message_id" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    case "$incident_start" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    recovered_epoch="$(date +%s)"
    duration_seconds=$((recovered_epoch - incident_start))

    if [ "$duration_seconds" -lt 0 ]; then
        duration_seconds=0
    fi

    duration_text="$(format_duration "$duration_seconds")"

    start_text="$(
        date -d "@$incident_start" \
            '+%d/%m/%Y %H:%M:%S' 2>/dev/null
    )"

    if [ -z "$start_text" ]; then
        start_text="Horário não disponível"
    fi

    recovered_text="$(date '+%d/%m/%Y %H:%M:%S')"

    case "$reason" in
        *"Can't connect to local MySQL server"*|\
        *"Couldn't connect to MySQL server"*)

            event_emoji="🔌"
            event_name="Falha de conexão entre FreeRADIUS e MySQL"
            ;;

        *"Failed to reconnect"*)

            event_emoji="🔄"
            event_name="Falha de reconexão SQL do FreeRADIUS"
            ;;

        *"no free connections are available"*)

            event_emoji="🚫"
            event_name="Esgotamento das conexões SQL do FreeRADIUS"
            ;;

        *"Something is blocking the server"*)

            event_emoji="🧱"
            event_name="Bloqueio ou saturação do FreeRADIUS"
            ;;

        *"SELECT 1"*)

            event_emoji="🩺"
            event_name="MySQL sem resposta ao teste de saúde"
            ;;

        *)

            event_emoji="⚠️"
            event_name="Falha crítica no MySQL/FreeRADIUS"
            ;;
    esac

    response="$(
        timeout 20 curl -sS \
            -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT}/editMessageText" \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "message_id=$message_id" \
            --data-urlencode "text=✅ MK-AUTH RECUPERADO \"$MKAUTH_NAME\"

Status: 🟢 INCIDENTE RESOLVIDO

MK-AUTH/VM: $MKAUTH_NAME
Servidor Linux: $(hostname)

$event_emoji Evento:
$event_name

📝 Erro detectado:
$reason

🚨 Início do problema:
$start_text

✅ Recuperado em:
$recovered_text

⏱️ Duração:
$duration_text

🗄️ MySQL: respondendo ao SELECT 1
📡 FreeRADIUS: funcionando
🔓 Porta UDP 1812: ativa" \
            2>&1
    )"

    if printf '%s' "$response" |
       grep -q '"ok":true'; then

        log "Mensagem original editada como recuperada."
        clear_incident_state
        return 0
    fi

    log "ERRO ao editar Telegram: $(compact_response "$response")"
    return 1
}

send_recovery_fallback() {
    local reason="$1"

    send_plain_telegram "✅ MK-AUTH RECUPERADO \"$MKAUTH_NAME\"

Status: 🟢 INCIDENTE RESOLVIDO

MK-AUTH/VM: $MKAUTH_NAME
Servidor Linux: $(hostname)

⚠️ Evento:
Falha crítica no MySQL/FreeRADIUS

📝 Erro original:
$reason

✅ Recuperado em:
$(date '+%d/%m/%Y %H:%M:%S')

🗄️ MySQL: respondendo ao SELECT 1
📡 FreeRADIUS: funcionando
🔓 Porta UDP 1812: ativa" || true
}

cooldown_active() {
    local now=""
    local last=""
    local difference=""

    [ -r "$COOLDOWN_FILE" ] || return 1

    read -r last < "$COOLDOWN_FILE"

    case "$last" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    case "$COOLDOWN_SECONDS" in
        ''|*[!0-9]*)
            COOLDOWN_SECONDS=180
            ;;
    esac

    now="$(date +%s)"
    difference=$((now - last))

    [ "$difference" -ge 0 ] &&
    [ "$difference" -lt "$COOLDOWN_SECONDS" ]
}

mark_recovery() {
    date +%s > "$COOLDOWN_FILE"
    chmod 600 "$COOLDOWN_FILE"
}

recover_mysql_radius() {
    local reason="$1"

    log "======================================================"
    log "ERRO CRÍTICO DETECTADO"
    log "MK-AUTH: $MKAUTH_NAME"
    log "Motivo completo: $reason"
    log "Serviço MySQL detectado: $MYSQL_SERVICE"
    log "Serviço FreeRADIUS detectado: $RADIUS_SERVICE"
    log "Iniciando recuperação automática."

    clear_incident_state
    send_incident_alert "$reason" || true

    log "Parando o FreeRADIUS antes da recuperação."

    service_action "$RADIUS_SERVICE" stop \
        >> "$MONITOR_LOG" 2>&1 || true

    log "Reiniciando o serviço $MYSQL_SERVICE."

    if ! service_action "$MYSQL_SERVICE" restart \
        >> "$MONITOR_LOG" 2>&1; then

        log "ERRO: não foi possível reiniciar o MySQL."

        service_action "$RADIUS_SERVICE" start \
            >> "$MONITOR_LOG" 2>&1 || true

        send_plain_telegram "❌ MYSQL NÃO RECUPERADO \"$MKAUTH_NAME\"

Não foi possível reiniciar o serviço $MYSQL_SERVICE.

Servidor: $(hostname)
Data: $(date '+%d/%m/%Y %H:%M:%S')" || true

        return 1
    fi

    if ! wait_mysql; then
        log "ERRO: MySQL não respondeu após 60 segundos."

        service_action "$RADIUS_SERVICE" start \
            >> "$MONITOR_LOG" 2>&1 || true

        send_plain_telegram "❌ MYSQL NÃO RECUPERADO \"$MKAUTH_NAME\"

O MySQL não respondeu ao SELECT 1 após 60 segundos.

Servidor: $(hostname)
Data: $(date '+%d/%m/%Y %H:%M:%S')" || true

        return 1
    fi

    log "MySQL está respondendo corretamente ao SELECT 1."
    log "Iniciando o serviço $RADIUS_SERVICE."

    if ! service_action "$RADIUS_SERVICE" start \
        >> "$MONITOR_LOG" 2>&1; then

        log "ERRO: não foi possível iniciar o FreeRADIUS."

        send_plain_telegram "❌ FREERADIUS NÃO INICIOU \"$MKAUTH_NAME\"

O MySQL voltou, mas o FreeRADIUS não iniciou.

Servidor: $(hostname)
Data: $(date '+%d/%m/%Y %H:%M:%S')" || true

        return 1
    fi

    if ! wait_radius; then
        log "ERRO: FreeRADIUS não confirmou processo/porta 1812."

        send_plain_telegram "⚠️ RECUPERAÇÃO PARCIAL \"$MKAUTH_NAME\"

MySQL: respondendo
FreeRADIUS: não confirmou processo ou porta UDP 1812

Servidor: $(hostname)
Data: $(date '+%d/%m/%Y %H:%M:%S')" || true

        return 1
    fi

    mark_recovery

    log "RECUPERAÇÃO CONCLUÍDA."
    log "MySQL: respondendo."
    log "FreeRADIUS: processo ativo e porta UDP 1812 aberta."
    log "Cooldown ativado por $COOLDOWN_SECONDS segundos."
    log "======================================================"

    if telegram_configured; then
        if ! edit_incident_as_recovered; then
            log "Não foi possível editar o alerta original."
            log "Enviando mensagem nova de recuperação."

            send_recovery_fallback "$reason"
            clear_incident_state
        fi
    fi

    return 0
}

CURRENT_INODE=""
CURRENT_SIZE="0"
LAST_INODE=""
LAST_OFFSET="0"
NEW_LINES=""
FOUND_PHRASE=""

if [ -f "$RADIUS_LOG" ]; then
    CURRENT_INODE="$(
        stat -c '%i' "$RADIUS_LOG" 2>/dev/null
    )"

    CURRENT_SIZE="$(
        stat -c '%s' "$RADIUS_LOG" 2>/dev/null
    )"

    case "$CURRENT_SIZE" in
        ''|*[!0-9]*)
            CURRENT_SIZE=0
            ;;
    esac

    if [ -r "$INODE_FILE" ]; then
        read -r LAST_INODE < "$INODE_FILE"
    fi

    if [ -r "$OFFSET_FILE" ]; then
        read -r LAST_OFFSET < "$OFFSET_FILE"
    fi

    case "$LAST_OFFSET" in
        ''|*[!0-9]*)
            LAST_OFFSET=0
            ;;
    esac

    if [ ! -f "$OFFSET_FILE" ]; then
        printf '%s\n' "$CURRENT_INODE" > "$INODE_FILE"
        printf '%s\n' "$CURRENT_SIZE" > "$OFFSET_FILE"

        log "Monitor iniciado."
        log "MK-AUTH: $MKAUTH_NAME"
        log "Posição inicial do radius.log: $CURRENT_SIZE bytes."
    else
        if [ "$CURRENT_INODE" != "$LAST_INODE" ] ||
           [ "$CURRENT_SIZE" -lt "$LAST_OFFSET" ]; then

            LAST_OFFSET=0
        fi

        if [ "$CURRENT_SIZE" -gt "$LAST_OFFSET" ]; then
            START_BYTE=$((LAST_OFFSET + 1))

            NEW_LINES="$(
                tail -c +"$START_BYTE" \
                    "$RADIUS_LOG" 2>/dev/null
            )"
        fi

        printf '%s\n' "$CURRENT_INODE" > "$INODE_FILE"
        printf '%s\n' "$CURRENT_SIZE" > "$OFFSET_FILE"

        for PHRASE in "${PHRASES[@]}"; do
            MATCH="$(
                printf '%s\n' "$NEW_LINES" |
                    grep -F -- "$PHRASE" |
                    head -n 1
            )"

            if [ -n "$MATCH" ]; then
                FOUND_PHRASE="$MATCH"
                break
            fi
        done
    fi
else
    log "AVISO: radius.log não encontrado."
fi

# Uma indisponibilidade real do banco ignora o cooldown.
if ! mysql_ok; then
    if [ -n "$FOUND_PHRASE" ]; then
        recover_mysql_radius "$FOUND_PHRASE"
    else
        recover_mysql_radius \
            "MySQL não respondeu ao comando SELECT 1."
    fi

    exit $?
fi

# Erro novo no log com o banco já respondendo.
if [ -n "$FOUND_PHRASE" ]; then
    if cooldown_active; then
        log "Erro SQL encontrado durante o cooldown."
        log "Reinício ignorado porque o MySQL está respondendo."
        log "Erro: $FOUND_PHRASE"
        exit 0
    fi

    recover_mysql_radius "$FOUND_PHRASE"
    exit $?
fi

exit 0
MONITOR

chown root:root "$SCRIPT"
chmod 700 "$SCRIPT"

# ==========================================================
# VALIDAR MONITOR
# ==========================================================

if ! bash -n "$SCRIPT"; then
    echo
    echo "ERRO: falha de sintaxe no monitor."
    exit 1
fi

# ==========================================================
# CRON A CADA 30 SEGUNDOS
# ==========================================================

cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

* * * * * root echo "\$(date '+\%F \%T') execução imediata" >> $CRON_LOG; timeout 120 $SCRIPT >> $CRON_LOG 2>&1
* * * * * root sleep 30; echo "\$(date '+\%F \%T') execução após 30 segundos" >> $CRON_LOG; timeout 120 $SCRIPT >> $CRON_LOG 2>&1
EOF

chown root:root "$CRON_FILE"
chmod 644 "$CRON_FILE"

# ==========================================================
# LOGROTATE
# ==========================================================

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

chown root:root "$LOGROTATE"
chmod 644 "$LOGROTATE"

# ==========================================================
# LIMPAR ESTADOS ANTERIORES
# ==========================================================

rm -f \
    "$STATE_DIR/radius.offset" \
    "$STATE_DIR/radius.inode" \
    "$STATE_DIR/last_successful_recovery" \
    "$STATE_DIR/telegram_message_id" \
    "$STATE_DIR/incident_start" \
    "$STATE_DIR/incident_reason" \
    /var/run/check_backup_freeradius.lock

# ==========================================================
# REINICIAR CRON
# ==========================================================

if command -v systemctl >/dev/null 2>&1 &&
   [ -d /run/systemd/system ]; then

    systemctl restart cron 2>/dev/null ||
    systemctl restart crond 2>/dev/null ||
    true
else
    service cron restart 2>/dev/null ||
    service crond restart 2>/dev/null ||
    true
fi

# Inicializa o ponto de leitura do radius.log.
"$SCRIPT"

# ==========================================================
# TESTAR TELEGRAM SOMENTE SE ATIVADO
# ==========================================================

if [ "$USAR_TELEGRAM" = "sim" ]; then
    echo
    echo "Testando Telegram..."

    TELEGRAM_RESPONSE="$(
        timeout 20 curl -sS \
            -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT}/sendMessage" \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=✅ MONITOR MK-AUTH INSTALADO

MK-AUTH/VM: $MKAUTH_NAME
Servidor Linux: $(hostname)

Monitor MySQL + FreeRADIUS instalado com sucesso.
Verificação automática: a cada 30 segundos.

Data: $(date '+%d/%m/%Y %H:%M:%S')" \
            2>&1
    )"

    if printf '%s' "$TELEGRAM_RESPONSE" |
       grep -q '"ok":true'; then

        echo "Telegram: OK"
    else
        echo "Telegram: ERRO"
        echo "$TELEGRAM_RESPONSE"
    fi
else
    echo
    echo "Telegram: desativado por escolha do usuário."
fi

# ==========================================================
# RESULTADO
# ==========================================================

echo
echo "=========================================================="
echo " INSTALAÇÃO CONCLUÍDA"
echo "=========================================================="
echo
echo "MK-AUTH:"
echo "  $MKAUTH_NAME"
echo
echo "Monitor:"
echo "  $SCRIPT"
echo
echo "Configuração:"
echo "  $CONFIG"
echo
echo "Cron:"
echo "  $CRON_FILE"
echo
echo "Log de eventos:"
echo "  $MONITOR_LOG"
echo
echo "Log das execuções:"
echo "  $CRON_LOG"
echo
echo "Entradas ativas encontradas:"

grep -Rni \
    '^[[:space:]]*[^#].*check_backup_freeradius\.sh' \
    /etc/crontab \
    /etc/cron.d \
    /var/spool/cron \
    /var/spool/cron/crontabs \
    2>/dev/null || true

echo
echo "Acompanhar execuções:"
echo "  tail -F $CRON_LOG"
echo
echo "Acompanhar falhas e recuperações:"
echo "  tail -F $MONITOR_LOG"
echo
echo "Teste controlado:"
echo "  service mysql stop"
echo
INSTALADOR

chmod 700 /root/instalar-monitor-mkauth.sh

bash -n /root/instalar-monitor-mkauth.sh &&
bash /root/instalar-monitor-mkauth.sh