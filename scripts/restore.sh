#!/usr/bin/env bash
# =============================================================================
# RESTORE - DOCKER VOLUMES
# =============================================================================
# Descrição: Restaura backups dos volumes Docker e bancos de dados.
#
# Uso:
#   ./scripts/restore.sh --service chatwoot --date 20250101_020000
#   ./scripts/restore.sh --service espocrm  --date 20250101_020000
#   ./scripts/restore.sh --list              # Lista backups disponíveis
#
# ATENÇÃO: O restore SUBSTITUI os dados existentes!
#          Os serviços serão parados temporariamente.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURAÇÕES
# -----------------------------------------------------------------------------
BACKUP_DIR="/opt/backups/docker-volumes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Cores
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
        INFO)  echo -e "${BLUE}[${timestamp}] [INFO]${NC}  ${message}" ;;
        OK)    echo -e "${GREEN}[${timestamp}] [OK]${NC}    ${message}" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] [WARN]${NC}  ${message}" ;;
        ERROR) echo -e "${RED}[${timestamp}] [ERROR]${NC} ${message}" ;;
    esac
}

usage() {
    cat <<EOF
Uso: $(basename "$0") [OPÇÕES]

Opções:
  --service SERVICE   Serviço a restaurar: chatwoot, espocrm
  --date TIMESTAMP    Timestamp do backup (formato: YYYYMMDD_HHMMSS)
  --list              Lista todos os backups disponíveis
  --help              Exibe esta ajuda

Exemplos:
  $(basename "$0") --list
  $(basename "$0") --service chatwoot --date 20250101_020000
  $(basename "$0") --service espocrm  --date 20250101_020000

ATENÇÃO: Esta operação é DESTRUTIVA e irá sobrescrever os dados atuais!
EOF
}

list_backups() {
    log INFO "Backups disponíveis em ${BACKUP_DIR}:"
    echo ""
    
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        log WARN "Nenhum backup encontrado em ${BACKUP_DIR}"
        return
    fi
    
    echo "ARQUIVO                                      TAMANHO    DATA"
    echo "─────────────────────────────────────────────────────────────────"
    
    find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
        -printf "%f\t%s\t%TY-%Tm-%Td %TH:%TM\n" \
        | sort -t$'\t' -k3 -r \
        | awk -F'\t' '{
            size = $2/1024/1024
            printf "%-44s %6.1f MB   %s\n", $1, size, $3
        }'
    
    echo ""
}

confirm_restore() {
    local service="$1"
    local timestamp="$2"
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║           ⚠️  ATENÇÃO - OPERAÇÃO DESTRUTIVA       ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Serviço  : ${YELLOW}${service}${NC}"
    echo -e "  Backup   : ${YELLOW}${timestamp}${NC}"
    echo ""
    echo "  Esta operação irá:"
    echo "  • Parar os containers do serviço"
    echo "  • SOBRESCREVER todos os dados atuais"
    echo "  • Restaurar a partir do backup selecionado"
    echo "  • Reiniciar os containers"
    echo ""
    
    read -r -p "  Tem certeza? Digite 'CONFIRMAR' para prosseguir: " confirmation
    
    if [[ "$confirmation" != "CONFIRMAR" ]]; then
        log WARN "Restore cancelado pelo usuário."
        exit 0
    fi
}

stop_services() {
    local service="$1"
    
    log INFO "Parando serviços do ${service}..."
    
    cd "$PROJECT_DIR"
    
    case "$service" in
        chatwoot)
            docker compose stop chatwoot-web chatwoot-sidekiq 2>/dev/null || true
            ;;
        espocrm)
            docker compose stop espocrm espocrm-daemon espocrm-websocket 2>/dev/null || true
            ;;
    esac
    
    log OK "Serviços do ${service} parados."
}

start_services() {
    local service="$1"
    
    log INFO "Iniciando serviços do ${service}..."
    
    cd "$PROJECT_DIR"
    
    case "$service" in
        chatwoot)
            docker compose start chatwoot-web chatwoot-sidekiq 2>/dev/null || true
            ;;
        espocrm)
            docker compose start espocrm espocrm-daemon espocrm-websocket 2>/dev/null || true
            ;;
    esac
    
    log OK "Serviços do ${service} iniciados."
}

restore_postgres() {
    local backup_file="$1"
    
    log INFO "Restaurando PostgreSQL (Chatwoot)..."
    
    if [[ ! -f "$backup_file" ]]; then
        log ERROR "Arquivo de backup não encontrado: ${backup_file}"
        return 1
    fi
    
    if [[ -f "${PROJECT_DIR}/chatwoot/.env" ]]; then
        # shellcheck source=/dev/null
        source <(grep -E '^POSTGRES_(USER|DB|PASSWORD)' "${PROJECT_DIR}/chatwoot/.env")
    fi
    
    local db_user="${POSTGRES_USER:-chatwoot}"
    local db_name="${POSTGRES_DB:-chatwoot_production}"
    
    log INFO "Descomprimindo e restaurando banco de dados..."
    
    if zcat "$backup_file" | docker exec -i chatwoot-postgres \
        psql -U "$db_user" -d "$db_name" \
        --quiet \
        2>/dev/null; then
        log OK "PostgreSQL restaurado com sucesso!"
    else
        log ERROR "Falha na restauração do PostgreSQL"
        return 1
    fi
}

restore_mariadb() {
    local backup_file="$1"
    
    log INFO "Restaurando MariaDB (EspoCRM)..."
    
    if [[ ! -f "$backup_file" ]]; then
        log ERROR "Arquivo de backup não encontrado: ${backup_file}"
        return 1
    fi
    
    if [[ -f "${PROJECT_DIR}/espocrm/.env" ]]; then
        # shellcheck source=/dev/null
        source <(grep -E '^(MYSQL_USER|MYSQL_PASSWORD|MYSQL_DATABASE)' "${PROJECT_DIR}/espocrm/.env")
    fi
    
    local db_user="${MYSQL_USER:-espocrm}"
    local db_pass="${MYSQL_PASSWORD:-}"
    local db_name="${MYSQL_DATABASE:-espocrm}"
    
    log INFO "Descomprimindo e restaurando banco de dados..."
    
    if zcat "$backup_file" | docker exec -i espocrm-mariadb \
        mysql -u "$db_user" -p"$db_pass" "$db_name" \
        2>/dev/null; then
        log OK "MariaDB restaurado com sucesso!"
    else
        log ERROR "Falha na restauração do MariaDB"
        return 1
    fi
}

restore_volume() {
    local volume_name="$1"
    local backup_file="$2"
    
    log INFO "Restaurando volume: ${volume_name}..."
    
    if [[ ! -f "$backup_file" ]]; then
        log ERROR "Arquivo de backup não encontrado: ${backup_file}"
        return 1
    fi
    
    # Verifica se o volume existe, se não, cria
    if ! docker volume inspect "$volume_name" &> /dev/null; then
        log INFO "Criando volume ${volume_name}..."
        docker volume create "$volume_name" > /dev/null
    fi
    
    # Limpa o volume e restaura
    if docker run --rm \
        -v "${volume_name}:/data" \
        -v "${BACKUP_DIR}:/backup:ro" \
        alpine:latest \
        sh -c "rm -rf /data/* /data/.* 2>/dev/null; tar xzf /backup/$(basename "$backup_file") -C /data" \
        2>/dev/null; then
        log OK "Volume ${volume_name} restaurado com sucesso!"
    else
        log ERROR "Falha na restauração do volume ${volume_name}"
        return 1
    fi
}

restore_chatwoot() {
    local timestamp="$1"
    
    local pg_backup="${BACKUP_DIR}/chatwoot-postgres_${timestamp}.sql.gz"
    local storage_backup="${BACKUP_DIR}/chatwoot-storage_${timestamp}.tar.gz"
    
    # Verifica existência dos backups
    local missing=0
    [[ ! -f "$pg_backup" ]] && log ERROR "Backup PostgreSQL não encontrado: $(basename "$pg_backup")" && ((missing++))
    
    if [[ $missing -gt 0 ]]; then
        log ERROR "Backup incompleto. Use --list para ver os backups disponíveis."
        exit 1
    fi
    
    stop_services "chatwoot"
    
    restore_postgres "$pg_backup"
    
    if [[ -f "$storage_backup" ]]; then
        restore_volume "chatwoot-storage" "$storage_backup"
    else
        log WARN "Backup de storage não encontrado. Pulando restauração de arquivos."
    fi
    
    start_services "chatwoot"
    
    log OK "Chatwoot restaurado com sucesso!"
}

restore_espocrm() {
    local timestamp="$1"
    
    local db_backup="${BACKUP_DIR}/espocrm-mariadb_${timestamp}.sql.gz"
    local data_backup="${BACKUP_DIR}/espocrm-data_${timestamp}.tar.gz"
    
    local missing=0
    [[ ! -f "$db_backup" ]] && log ERROR "Backup MariaDB não encontrado: $(basename "$db_backup")" && ((missing++))
    
    if [[ $missing -gt 0 ]]; then
        log ERROR "Backup incompleto. Use --list para ver os backups disponíveis."
        exit 1
    fi
    
    stop_services "espocrm"
    
    restore_mariadb "$db_backup"
    
    if [[ -f "$data_backup" ]]; then
        restore_volume "espocrm-data" "$data_backup"
    else
        log WARN "Backup de dados não encontrado. Pulando restauração de arquivos."
    fi
    
    start_services "espocrm"
    
    log OK "EspoCRM restaurado com sucesso!"
}

# -----------------------------------------------------------------------------
# PARSE DE ARGUMENTOS
# -----------------------------------------------------------------------------

SERVICE=""
DATE=""
LIST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service)
            SERVICE="$2"
            shift 2
            ;;
        --date)
            DATE="$2"
            shift 2
            ;;
        --list)
            LIST=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log ERROR "Argumento desconhecido: $1"
            usage
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# EXECUÇÃO PRINCIPAL
# -----------------------------------------------------------------------------

if [[ "$LIST" == "true" ]]; then
    list_backups
    exit 0
fi

if [[ -z "$SERVICE" ]] || [[ -z "$DATE" ]]; then
    log ERROR "Parâmetros obrigatórios: --service e --date"
    usage
    exit 1
fi

if [[ ! "$SERVICE" =~ ^(chatwoot|espocrm)$ ]]; then
    log ERROR "Serviço inválido: ${SERVICE}. Use: chatwoot ou espocrm"
    exit 1
fi

confirm_restore "$SERVICE" "$DATE"

log INFO "=================================================="
log INFO "INICIANDO RESTORE"
log INFO "Serviço  : ${SERVICE}"
log INFO "Timestamp: ${DATE}"
log INFO "=================================================="

case "$SERVICE" in
    chatwoot) restore_chatwoot "$DATE" ;;
    espocrm)  restore_espocrm "$DATE"  ;;
esac

log INFO "=================================================="
log OK "RESTORE CONCLUÍDO COM SUCESSO"
log INFO "=================================================="
