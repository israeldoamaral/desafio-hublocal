#!/usr/bin/env bash
# =============================================================================
# BACKUP AUTOMATIZADO - DOCKER VOLUMES
# =============================================================================
# Descrição: Realiza backup de todos os volumes Docker críticos da stack.
#            Comprime com gzip, nomeia com timestamp e envia para S3 (opcional).
#
# Uso:
#   ./scripts/backup.sh              # Backup completo
#   ./scripts/backup.sh chatwoot     # Backup apenas do Chatwoot
#   ./scripts/backup.sh espocrm      # Backup apenas do EspoCRM
#
# Cron (diário às 02:00):
#   0 2 * * * /opt/stack/scripts/backup.sh >> /var/log/backup.log 2>&1
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

# S3 (opcional - deixar em branco para desabilitar)
S3_BUCKET=""
S3_PREFIX="backups/docker-volumes"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Notificação (opcional - Slack Webhook)
SLACK_WEBHOOK=""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

backup_postgres() {
    local backup_file="${BACKUP_DIR}/chatwoot-postgres_${TIMESTAMP}.sql.gz"
    
    log INFO "Iniciando backup do PostgreSQL (Chatwoot)..."
    
    # Verifica se o container está rodando
    if ! docker ps --format '{{.Names}}' | grep -q "^chatwoot-postgres$"; then
        log WARN "Container chatwoot-postgres não está rodando. Pulando backup do PostgreSQL."
        return 1
    fi
    
    # Carrega variáveis do env
    if [[ -f "${PROJECT_DIR}/chatwoot/.env" ]]; then
        # shellcheck source=/dev/null
        source <(grep -E '^POSTGRES_(USER|DB|PASSWORD)' "${PROJECT_DIR}/chatwoot/.env")
    fi
    
    local db_user="${POSTGRES_USER:-chatwoot}"
    local db_name="${POSTGRES_DB:-chatwoot_production}"
    
    if docker exec chatwoot-postgres \
        pg_dump -U "$db_user" -d "$db_name" \
        --no-password \
        --format=plain \
        --clean \
        --if-exists \
        2>/dev/null | gzip > "$backup_file"; then
        
        local size
        size=$(du -sh "$backup_file" | cut -f1)
        log OK "PostgreSQL backup concluído: $(basename "$backup_file") (${size})"
        echo "$backup_file"
    else
        log ERROR "Falha no backup do PostgreSQL"
        rm -f "$backup_file"
        return 1
    fi
}

backup_mariadb() {
    local backup_file="${BACKUP_DIR}/espocrm-mariadb_${TIMESTAMP}.sql.gz"
    
    log INFO "Iniciando backup do MariaDB (EspoCRM)..."
    
    if ! docker ps --format '{{.Names}}' | grep -q "^espocrm-mariadb$"; then
        log WARN "Container espocrm-mariadb não está rodando. Pulando backup do MariaDB."
        return 1
    fi
    
    if [[ -f "${PROJECT_DIR}/espocrm/.env" ]]; then
        # shellcheck source=/dev/null
        source <(grep -E '^(MYSQL_USER|MYSQL_PASSWORD|MYSQL_DATABASE|MYSQL_ROOT_PASSWORD)' "${PROJECT_DIR}/espocrm/.env")
    fi
    
    local db_user="${MYSQL_USER:-espocrm}"
    local db_pass="${MYSQL_PASSWORD:-}"
    local db_name="${MYSQL_DATABASE:-espocrm}"
    
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
        log OK "MariaDB backup concluído: $(basename "$backup_file") (${size})"
        echo "$backup_file"
    else
        log ERROR "Falha no backup do MariaDB"
        rm -f "$backup_file"
        return 1
    fi
}

backup_volume() {
    local volume_name="$1"
    local backup_file="${BACKUP_DIR}/${volume_name}_${TIMESTAMP}.tar.gz"
    
    log INFO "Backup do volume: ${volume_name}..."
    
    # Verifica se o volume existe
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
        log OK "Volume backup concluído: $(basename "$backup_file") (${size})"
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
    
    log OK "Removidos ${count} arquivos de backup antigos."
}

print_summary() {
    local start_time="$1"
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log INFO "=================================================="
    log INFO "RESUMO DO BACKUP"
    log INFO "=================================================="
    log INFO "Timestamp   : ${TIMESTAMP}"
    log INFO "Duração     : ${duration}s"
    log INFO "Diretório   : ${BACKUP_DIR}"
    log INFO "Retenção    : ${RETENTION_DAYS} dias"
    
    local total_size
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "N/A")
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
    log INFO "INICIANDO BACKUP - ${TIMESTAMP}"
    log INFO "Alvo: ${target}"
    log INFO "=================================================="
    
    check_dependencies
    create_backup_dir
    
    case "$target" in
        all|chatwoot)
            # Banco de dados PostgreSQL
            if file=$(backup_postgres 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi
            
            # Volume de storage do Chatwoot
            if file=$(backup_volume "chatwoot-storage" 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi
            ;;&
        
        all|espocrm)
            # Banco de dados MariaDB
            if file=$(backup_mariadb 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi
            
            # Volume de dados do EspoCRM
            if file=$(backup_volume "espocrm-data" 2>&1); then
                backup_files+=("$file")
                upload_to_s3 "$file" || true
            else
                ((failed++)) || true
            fi
            ;;
        
        *)
            log ERROR "Alvo inválido: ${target}. Use: all, chatwoot ou espocrm"
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
        log OK "Backup concluído com sucesso! ${#backup_files[@]} arquivo(s) criado(s)."
        notify_slack "success" "Backup concluído com sucesso em ${TIMESTAMP}"
    fi
}

main "$@"
