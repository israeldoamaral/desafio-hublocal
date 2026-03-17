#!/usr/bin/env bash
# =============================================================================
# BACKUP AUTOMATIZADO - DOCKER VOLUMES
# =============================================================================
# Descrição: Realiza backup de todos os volumes Docker críticos da stack.
#            Comprime com gzip, nomeia com timestamp e envia para S3 (opcional).
#
# Uso:
#   ./scripts/backup.sh              # Backup completo (Chatwoot + EspoCRM)
#   ./scripts/backup.sh chatwoot     # Backup apenas do Chatwoot
#   ./scripts/backup.sh espocrm      # Backup apenas do EspoCRM
#
# Cron (diário às 02:00):
#   0 2 * * * /opt/stack/scripts/backup.sh >> /var/log/backup.log 2>&1
#
# Volumes cobertos:
#   Chatwoot : chatwoot-postgres-data (pg_dump) + chatwoot-storage (tar.gz)
#   EspoCRM  : espocrm-mariadb-data  (mysqldump) + espocrm-data (tar.gz)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURAÇÕES
# -----------------------------------------------------------------------------
BACKUP_DIR="/opt/backups/docker-volumes"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7
LOG_FILE="/var/log/backup.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# S3 (opcional — deixar em branco para desabilitar)
S3_BUCKET=""
S3_PREFIX="backups/docker-volumes"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Notificação via Slack Webhook (opcional — deixar em branco para desabilitar)
SLACK_WEBHOOK=""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# FUNÇÕES AUXILIARES
# -----------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO)  echo -e "${BLUE}[${timestamp}] [INFO]${NC}  ${message}" | tee -a "$LOG_FILE" ;;
        OK)    echo -e "${GREEN}[${timestamp}] [OK]${NC}    ${message}" | tee -a "$LOG_FILE" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] [WARN]${NC}  ${message}" | tee -a "$LOG_FILE" ;;
        ERROR) echo -e "${RED}[${timestamp}] [ERROR]${NC} ${message}" | tee -a "$LOG_FILE" ;;
    esac
}

notify_slack() {
    local status="$1"
    local message="$2"

    if [[ -n "$SLACK_WEBHOOK" ]]; then
        local emoji
        [[ "$status" == "success" ]] && emoji="✅" || emoji="❌"
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            --data "{\"text\":\"${emoji} *Backup ${status}*: ${message}\"}" \
            > /dev/null 2>&1 || true
    fi
}

check_dependencies() {
    local deps=("docker" "gzip" "tar")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log ERROR "Dependência não encontrada: $dep"
            exit 1
        fi
    done

    if [[ -n "$S3_BUCKET" ]] && ! command -v aws &> /dev/null; then
        log WARN "AWS CLI não encontrado. Upload para S3 desabilitado."
        S3_BUCKET=""
    fi
}

create_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    chmod 750 "$BACKUP_DIR"
}

# -----------------------------------------------------------------------------
# BACKUP - PostgreSQL (Chatwoot)
# Container : chatwoot-postgres
# Volume    : chatwoot-postgres-data
# Variáveis : POSTGRES_USERNAME / POSTGRES_DATABASE (lidas do .env raiz)
# -----------------------------------------------------------------------------
backup_postgres() {
    local backup_file="${BACKUP_DIR}/chatwoot-postgres_${TIMESTAMP}.sql.gz"

    log INFO "Iniciando backup do PostgreSQL (chatwoot-postgres)..."

    if ! docker ps --format '{{.Names}}' | grep -q "^chatwoot-postgres$"; then
        log WARN "Container chatwoot-postgres não está rodando. Pulando backup."
        return 1
    fi

    # Lê variáveis do .env raiz do projeto
    local db_user db_name
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        db_user=$(grep -E '^POSTGRES_USERNAME=' "${PROJECT_DIR}/.env" | cut -d= -f2 | tr -d '"' || true)
        db_name=$(grep -E '^POSTGRES_DATABASE=' "${PROJECT_DIR}/.env" | cut -d= -f2 | tr -d '"' || true)
    fi
    db_user="${db_user:-chatwoot}"
    db_name="${db_name:-chatwoot_production}"

    if docker exec chatwoot-postgres \
        pg_dump -U "$db_user" -d "$db_name" \
        --no-password \
        --format=plain \
        --clean \
        --if-exists \
        2>/dev/null | gzip > "$backup_file"; then

        local size
        size=$(du -sh "$backup_file" | cut -f1)
        log OK "PostgreSQL backup: $(basename "$backup_file") (${size})"
        echo "$backup_file"
    else
        log ERROR "Falha no backup do PostgreSQL"
        rm -f "$backup_file"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# BACKUP - MariaDB (EspoCRM)
# Container : espocrm-mariadb
# Volume    : espocrm-mariadb-data
# Variáveis : MYSQL_USER / MYSQL_PASSWORD / MYSQL_DATABASE (lidas do .env raiz)
# -----------------------------------------------------------------------------
backup_mariadb() {
    local backup_file="${BACKUP_DIR}/espocrm-mariadb_${TIMESTAMP}.sql.gz"

    log INFO "Iniciando backup do MariaDB (espocrm-mariadb)..."

    if ! docker ps --format '{{.Names}}' | grep -q "^espocrm-mariadb$"; then
        log WARN "Container espocrm-mariadb não está rodando. Pulando backup."
        return 1
    fi

    local db_user db_pass db_name
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        db_user=$(grep -E '^MYSQL_USER=' "${PROJECT_DIR}/.env" | cut -d= -f2 | tr -d '"' || true)
        db_pass=$(grep -E '^MYSQL_PASSWORD=' "${PROJECT_DIR}/.env" | cut -d= -f2 | tr -d '"' || true)
        db_name=$(grep -E '^MYSQL_DATABASE=' "${PROJECT_DIR}/.env" | cut -d= -f2 | tr -d '"' || true)
    fi
    db_user="${db_user:-espocrm}"
    db_pass="${db_pass:-}"
    db_name="${db_name:-espocrm}"

    if docker exec espocrm-mariadb \
        mysqldump \
        -u "$db_user" \
        -p"$db_pass" \
        --single-transaction \
        --routines \
        --triggers \
        --add-drop-table \
        "$db_name" \
        2>/dev/null | gzip > "$backup_file"; then

        local size
        size=$(du -sh "$backup_file" | cut -f1)
        log OK "MariaDB backup: $(basename "$backup_file") (${size})"
        echo "$backup_file"
    else
        log ERROR "Falha no backup do MariaDB"
        rm -f "$backup_file"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# BACKUP - Volume Docker genérico (tar.gz via container alpine)
# Volumes cobertos:
#   chatwoot-storage  — arquivos enviados pelos usuários (/app/storage)
#   espocrm-data      — arquivos, configurações e uploads (/var/www/html)
# -----------------------------------------------------------------------------
backup_volume() {
    local volume_name="$1"
    local backup_file="${BACKUP_DIR}/${volume_name}_${TIMESTAMP}.tar.gz"

    log INFO "Backup do volume: ${volume_name}..."

    if ! docker volume inspect "$volume_name" &> /dev/null; then
        log WARN "Volume ${volume_name} não encontrado. Pulando."
        return 1
    fi

    if docker run --rm \
        -v "${volume_name}:/data:ro" \
        -v "${BACKUP_DIR}:/backup" \
        alpine:latest \
        tar czf "/backup/$(basename "$backup_file")" \
        -C /data . \
        2>/dev/null; then

        local size
        size=$(du -sh "$backup_file" | cut -f1)
        log OK "Volume backup: $(basename "$backup_file") (${size})"
        echo "$backup_file"
    else
        log ERROR "Falha no backup do volume ${volume_name}"
        rm -f "$backup_file"
        return 1
    fi
}

upload_to_s3() {
    local file="$1"

    if [[ -z "$S3_BUCKET" ]]; then
        return 0
    fi

    local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$file")"
    log INFO "Enviando para S3: ${s3_path}..."

    if aws s3 cp "$file" "$s3_path" \
        --region "$AWS_REGION" \
        --storage-class STANDARD_IA \
        --quiet; then
        log OK "Upload S3 concluído: $(basename "$file")"
    else
        log ERROR "Falha no upload para S3: $(basename "$file")"
        return 1
    fi
}

cleanup_old_backups() {
    log INFO "Removendo backups com mais de ${RETENTION_DAYS} dias..."

    local count
    count=$(find "$BACKUP_DIR" -type f \
        \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
        -mtime "+${RETENTION_DAYS}" | wc -l)

    find "$BACKUP_DIR" -type f \
        \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
        -mtime "+${RETENTION_DAYS}" \
        -delete

    log OK "Removidos ${count} arquivo(s) de backup antigos."
}

print_summary() {
    local start_time="$1"
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    local total_size
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "N/A")

    log INFO "=================================================="
    log INFO "RESUMO DO BACKUP"
    log INFO "Timestamp   : ${TIMESTAMP}"
    log INFO "Duração     : ${duration}s"
    log INFO "Diretório   : ${BACKUP_DIR}"
    log INFO "Retenção    : ${RETENTION_DAYS} dias"
    log INFO "Uso total   : ${total_size}"
    log INFO "=================================================="
}

# -----------------------------------------------------------------------------
# FUNÇÃO PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    local target="${1:-all}"
    local start_time
    start_time=$(date +%s)
    local failed=0
    local backup_files=()

    log INFO "=================================================="
    log INFO "INICIANDO BACKUP — ${TIMESTAMP}"
    log INFO "Alvo: ${target}"
    log INFO "=================================================="

    check_dependencies
    create_backup_dir

    case "$target" in
        all|chatwoot)
            # Dump do PostgreSQL — chatwoot-postgres-data
            if file=$(backup_postgres 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi

            # Volume de arquivos — chatwoot-storage
            if file=$(backup_volume "chatwoot-storage" 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi
            ;;&

        all|espocrm)
            # Dump do MariaDB — espocrm-mariadb-data
            if file=$(backup_mariadb 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi

            # Volume de dados/configs — espocrm-data
            if file=$(backup_volume "espocrm-data" 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi
            ;;

        *)
            log ERROR "Alvo inválido: '${target}'. Use: all, chatwoot ou espocrm"
            exit 1
            ;;
    esac

    cleanup_old_backups
    print_summary "$start_time"

    if [[ $failed -gt 0 ]]; then
        log ERROR "Backup concluído com ${failed} erro(s)."
        notify_slack "falhou" "${failed} backup(s) falharam em ${TIMESTAMP}"
        exit 1
    else
        log OK "Backup concluído! ${#backup_files[@]} arquivo(s) criado(s)."
        notify_slack "success" "Backup concluído com sucesso em ${TIMESTAMP}"
    fi
}

main "$@"
