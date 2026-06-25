#!/bin/bash
# =============================================================
#  Marzban SQLite → MySQL 8.0 Migration
#  Ubuntu 22.04 | Marzban via docker-compose
# =============================================================

set -uo pipefail

# ─── Paths ───────────────────────────────────────────────────
MARZBAN_DIR="/opt/marzban"
MARZBAN_DATA="/var/lib/marzban"
ENV_FILE="$MARZBAN_DIR/.env"
COMPOSE_FILE="$MARZBAN_DIR/docker-compose.yml"
SQLITE_DB="$MARZBAN_DATA/db.sqlite3"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/marzban-backup-$TIMESTAMP"
DUMP_FILE="/tmp/marzban_dump_$TIMESTAMP.sql"

MYSQL_DATABASE="marzban"
MYSQL_MARZBAN_USER="marzban"
MYSQL_GRAFANA_USER="grafana_ro"

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log_step()  { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; }
log_info()  { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "  ${RED}✗${NC} $1"; }
log_data()  { echo -e "  ${CYAN}→${NC} $1"; }

# ─── Error handler ───────────────────────────────────────────
trap 'on_error $LINENO' ERR
on_error() {
    echo ""
    log_error "Script failed on line $1. Marzban was stopped."
    log_warn  "Backup is at: $BACKUP_DIR"
    log_warn  "To restore SQLite manually:"
    log_warn  "  1. Revert $ENV_FILE from $BACKUP_DIR/marzban-opt/"
    log_warn  "  2. Revert $COMPOSE_FILE from $BACKUP_DIR/marzban-opt/"
    log_warn  "  3. cd $MARZBAN_DIR && docker compose up -d marzban"
    exit 1
}

# ─── Pre-flight checks ───────────────────────────────────────
preflight() {
    log_step "Pre-flight checks"

    [[ $EUID -ne 0 ]] && { log_error "Run as root (sudo -i or sudo bash script.sh)"; exit 1; }
    [[ -f "$ENV_FILE" ]]     || { log_error ".env not found at $ENV_FILE"; exit 1; }
    [[ -f "$COMPOSE_FILE" ]] || { log_error "docker-compose.yml not found at $COMPOSE_FILE"; exit 1; }
    [[ -f "$SQLITE_DB" ]]    || { log_error "SQLite DB not found at $SQLITE_DB"; exit 1; }

    # Check not already on MySQL
    if grep -q "mysql+pymysql" "$ENV_FILE" 2>/dev/null; then
        log_error "Marzban is already configured to use MySQL. Aborting."
        exit 1
    fi

    # Check MySQL service not already in compose
    if grep -q "marzban-mysql" "$COMPOSE_FILE" 2>/dev/null; then
        log_error "MySQL service already exists in docker-compose.yml. Aborting."
        exit 1
    fi

    # Install dependencies if missing
    if ! command -v sqlite3 &>/dev/null; then
        log_warn "sqlite3 not found — installing..."
        apt-get install -y sqlite3 -qq
    fi
    if ! python3 -c "import yaml" &>/dev/null; then
        log_warn "python3-yaml not found — installing..."
        apt-get install -y python3-yaml -qq
    fi

    log_info "All checks passed"
}

# ─── Interactive config ──────────────────────────────────────
configure() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Marzban  SQLite → MySQL 8.0 Migration     ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Backup will be saved to:  ${CYAN}$BACKUP_DIR${NC}"
    echo -e "  SQLite DB:                ${CYAN}$SQLITE_DB${NC}"
    echo ""

    read -rp "  Grafana server IP (for external MySQL access, leave empty to skip): " GRAFANA_IP
    GRAFANA_IP="${GRAFANA_IP:-}"

    echo ""
    echo -e "${YELLOW}  ⚠  Marzban will be briefly stopped during migration.${NC}"
    echo -e "${YELLOW}  ⚠  Downtime estimate: 2–5 minutes.${NC}"
    echo ""
    read -rp "  Press ENTER to start, Ctrl+C to cancel..."

    export GRAFANA_IP
}

# ─── Generate secure passwords ───────────────────────────────
gen_passwords() {
    # Only alphanumeric — safe for shell, .env, MySQL
    gen_pass() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 36; }
    MYSQL_ROOT_PASSWORD=$(gen_pass)
    MYSQL_MARZBAN_PASSWORD=$(gen_pass)
    MYSQL_GRAFANA_PASSWORD=$(gen_pass)
    export MYSQL_ROOT_PASSWORD MYSQL_MARZBAN_PASSWORD MYSQL_GRAFANA_PASSWORD
}

# ─── Step 1: Backup ──────────────────────────────────────────
step_backup() {
    log_step "Step 1/8 — Backup"

    mkdir -p "$BACKUP_DIR"
    cp -r "$MARZBAN_DIR"  "$BACKUP_DIR/marzban-opt"
    cp -r "$MARZBAN_DATA" "$BACKUP_DIR/marzban-var"

    # Save credentials separately
    cat > "$BACKUP_DIR/mysql-credentials.txt" << EOF
=== MySQL Credentials ===
Generated: $(date)

Root password:       $MYSQL_ROOT_PASSWORD
Marzban DB user:     $MYSQL_MARZBAN_USER / $MYSQL_MARZBAN_PASSWORD
Grafana RO user:     $MYSQL_GRAFANA_USER / $MYSQL_GRAFANA_PASSWORD

Database: $MYSQL_DATABASE
Host (local):        127.0.0.1:3306
Host (Grafana):      <marzban-server-ip>:3306

Grafana datasource (MySQL):
  Host:      <marzban-server-ip>:3306
  Database:  $MYSQL_DATABASE
  User:      $MYSQL_GRAFANA_USER
  Password:  $MYSQL_GRAFANA_PASSWORD
EOF
    chmod 600 "$BACKUP_DIR/mysql-credentials.txt"

    log_info "Backup saved:      $BACKUP_DIR"
    log_info "Credentials file:  $BACKUP_DIR/mysql-credentials.txt"
}

# ─── Step 2: Stop Marzban ────────────────────────────────────
step_stop_marzban() {
    log_step "Step 2/8 — Stop Marzban"
    cd "$MARZBAN_DIR"
    docker compose stop marzban 2>/dev/null || true
    sleep 3
    log_info "Marzban stopped"
}

# ─── Step 3: Dump SQLite ─────────────────────────────────────
step_dump_sqlite() {
    log_step "Step 3/8 — Dump SQLite"

    # Row counts before dump (for verification later)
    SQLITE_USERS=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM users;"   2>/dev/null || echo "0")
    SQLITE_ADMINS=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM admins;" 2>/dev/null || echo "0")
    SQLITE_NODES=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM nodes;"   2>/dev/null || echo "0")
    log_data "SQLite — users: $SQLITE_USERS | admins: $SQLITE_ADMINS | nodes: $SQLITE_NODES"
    export SQLITE_USERS SQLITE_ADMINS SQLITE_NODES

    # Dump data only (DDL will be created by Marzban's alembic migrations)
    sqlite3 "$SQLITE_DB" '.dump --data-only' \
        | sed "s/INSERT INTO \([^ ]*\)/REPLACE INTO \`\1\`/g" \
        | sed -E "s/'([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]+'/'\1'/g" \
        > "$DUMP_FILE"

    DUMP_LINES=$(wc -l < "$DUMP_FILE")
    [[ $DUMP_LINES -gt 0 ]] || { log_error "Dump is empty! Aborting."; exit 1; }
    log_info "Dump created: $DUMP_LINES lines"
}

# ─── Step 4: Update docker-compose.yml ───────────────────────
step_update_compose() {
    log_step "Step 4/8 — Update docker-compose.yml"

    if [[ -n "$GRAFANA_IP" ]]; then
        MYSQL_BIND="0.0.0.0"
        log_warn "MySQL will bind to 0.0.0.0 (external access). Firewall will be configured."
    else
        MYSQL_BIND="127.0.0.1"
        log_info "MySQL will bind to 127.0.0.1 (local only)"
    fi

python3 - "$COMPOSE_FILE" "$MYSQL_BIND" "$MYSQL_ROOT_PASSWORD" \
    "$MYSQL_MARZBAN_USER" "$MYSQL_MARZBAN_PASSWORD" \
    "$MYSQL_DATABASE" << 'PYEOF'
import yaml, sys

compose_file = sys.argv[1]
mysql_bind   = sys.argv[2]
root_pass    = sys.argv[3]
db_user      = sys.argv[4]
db_pass      = sys.argv[5]
db_name      = sys.argv[6]

with open(compose_file, 'r') as f:
    config = yaml.safe_load(f)

config['services']['mysql'] = {
    'image':          'mysql:8.0',
    'container_name': 'marzban-mysql',
    'restart':        'unless-stopped',
    'network_mode':   'host',
    'environment': {
        'MYSQL_DATABASE':      db_name,
        'MYSQL_ROOT_PASSWORD': root_pass,
        'MYSQL_USER':          db_user,
        'MYSQL_PASSWORD':      db_pass,
    },
    'volumes': ['/var/lib/marzban/mysql:/var/lib/mysql'],
    'command': (
        f'--bind-address={mysql_bind} '
        '--mysqlx-bind-address=127.0.0.1 '
        '--character-set-server=utf8mb4 '
        '--collation-server=utf8mb4_unicode_ci '
        '--disable-log-bin '
        '--max-connections=500 '
        '--innodb-buffer-pool-size=256M '
        '--sql-mode=STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'
    ),
    'healthcheck': {
        'test':         ['CMD', 'mysqladmin', 'ping', '-h', '127.0.0.1', '-uroot', f'-p{root_pass}'],
        'interval':     '10s',
        'timeout':      '5s',
        'retries':      10,
        'start_period': '30s',
    }
}

# Add depends_on mysql → marzban
svc = config['services'].get('marzban', {})
deps = svc.get('depends_on', {})
if isinstance(deps, list):
    deps = {s: {'condition': 'service_started'} for s in deps}
elif deps is None:
    deps = {}
deps['mysql'] = {'condition': 'service_healthy'}
config['services']['marzban']['depends_on'] = deps

with open(compose_file, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print("  ✓ docker-compose.yml updated")
PYEOF

    log_info "docker-compose.yml updated"
}

# ─── Step 5: Update .env ─────────────────────────────────────
step_update_env() {
    log_step "Step 5/8 — Update .env"

    # Comment out old SQLite URL
    sed -i 's|^\(SQLALCHEMY_DATABASE_URL\)|#\1|g' "$ENV_FILE"

    # Append MySQL config
    cat >> "$ENV_FILE" << EOF

# ── MySQL (migrated from SQLite on $(date)) ──
SQLALCHEMY_DATABASE_URL="mysql+pymysql://${MYSQL_MARZBAN_USER}:${MYSQL_MARZBAN_PASSWORD}@127.0.0.1:3306/${MYSQL_DATABASE}"
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
EOF

    log_info ".env updated"
}

# ─── Step 6: Start MySQL, create schema ──────────────────────
step_init_mysql() {
    log_step "Step 6/8 — Start MySQL & create schema"
    cd "$MARZBAN_DIR"

    # Start MySQL only
    docker compose up -d mysql
    log_info "Waiting for MySQL to become healthy..."

    RETRIES=40
    while [[ $RETRIES -gt 0 ]]; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' marzban-mysql 2>/dev/null || echo "unknown")
        if [[ "$STATUS" == "healthy" ]]; then
            log_info "MySQL is healthy"
            break
        fi
        printf "."
        sleep 3
        RETRIES=$((RETRIES - 1))
    done
    echo ""
    [[ $RETRIES -eq 0 ]] && { log_error "MySQL failed to become healthy. Check: docker logs marzban-mysql"; exit 1; }

    # Start Marzban briefly — alembic will create all tables
    log_info "Starting Marzban to run alembic migrations..."
    docker compose up -d marzban

    # Wait for schema creation (alembic runs at startup)
    RETRIES=20
    while [[ $RETRIES -gt 0 ]]; do
        TABLES=$(docker exec marzban-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
            -h127.0.0.1 "$MYSQL_DATABASE" -sN -e "SHOW TABLES;" 2>/dev/null | wc -l || echo "0")
        if [[ "$TABLES" -gt 3 ]]; then
            log_info "Schema created: $TABLES tables"
            break
        fi
        printf "."
        sleep 3
        RETRIES=$((RETRIES - 1))
    done
    echo ""
    [[ $RETRIES -eq 0 ]] && { log_error "Schema creation timed out. Check: docker logs marzban"; exit 1; }

    # Stop Marzban — import data cleanly without active writes
    docker compose stop marzban
    sleep 2
    log_info "Marzban stopped for data import"
}

# ─── Step 7: Import data ─────────────────────────────────────
step_import_data() {
    log_step "Step 7/8 — Import data"

    # Copy dump into the MySQL container
    docker cp "$DUMP_FILE" marzban-mysql:/tmp/marzban_dump.sql

    # Import — skip alembic_version conflicts (schema already at latest)
    docker exec marzban-mysql mysql \
        -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -h127.0.0.1 \
        "$MYSQL_DATABASE" \
        -e "SET FOREIGN_KEY_CHECKS=0; SET NAMES utf8mb4; SOURCE /tmp/marzban_dump.sql; SET FOREIGN_KEY_CHECKS=1;" \
        2>&1 | grep -v "Using a password" | grep -v "^$" || true

    log_info "Import finished"

    # ── Verify row counts ──
    MYSQL_USERS=$(docker exec marzban-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -h127.0.0.1 "$MYSQL_DATABASE" -sN -e "SELECT COUNT(*) FROM users;"  2>/dev/null | tail -1)
    MYSQL_ADMINS=$(docker exec marzban-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -h127.0.0.1 "$MYSQL_DATABASE" -sN -e "SELECT COUNT(*) FROM admins;" 2>/dev/null | tail -1)
    MYSQL_NODES=$(docker exec marzban-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -h127.0.0.1 "$MYSQL_DATABASE" -sN -e "SELECT COUNT(*) FROM nodes;"  2>/dev/null | tail -1)

    echo ""
    echo -e "  ${BOLD}Table     SQLite    MySQL     Match${NC}"
    echo -e "  ─────────────────────────────────────"
    check_table() {
        local name=$1 sqlite_cnt=$2 mysql_cnt=$3
        if [[ "$sqlite_cnt" == "$mysql_cnt" ]]; then
            echo -e "  $name     $sqlite_cnt         $mysql_cnt         ${GREEN}✓${NC}"
        else
            echo -e "  $name     $sqlite_cnt         $mysql_cnt         ${RED}✗ MISMATCH${NC}"
        fi
    }
    check_table "users " "$SQLITE_USERS"  "$MYSQL_USERS"
    check_table "admins" "$SQLITE_ADMINS" "$MYSQL_ADMINS"
    check_table "nodes " "$SQLITE_NODES"  "$MYSQL_NODES"
    echo ""

    if [[ "$MYSQL_USERS" != "$SQLITE_USERS" ]]; then
        log_warn "User count mismatch — review before going live"
        log_warn "You can restore from: $BACKUP_DIR"
    else
        log_info "Data integrity verified ✓"
    fi

    # Cleanup dump from container
    docker exec marzban-mysql rm -f /tmp/marzban_dump.sql 2>/dev/null || true
    rm -f "$DUMP_FILE"
}

# ─── Step 8: Grafana user + firewall ─────────────────────────
step_grafana_setup() {
    log_step "Step 8/8 — Grafana read-only user"

    docker exec marzban-mysql mysql \
        -uroot -p"$MYSQL_ROOT_PASSWORD" \
        -h127.0.0.1 \
        -e "
            CREATE USER IF NOT EXISTS '${MYSQL_GRAFANA_USER}'@'%'
                IDENTIFIED BY '${MYSQL_GRAFANA_PASSWORD}';
            GRANT SELECT ON ${MYSQL_DATABASE}.* TO '${MYSQL_GRAFANA_USER}'@'%';
            FLUSH PRIVILEGES;
        " 2>/dev/null
    log_info "Read-only user '$MYSQL_GRAFANA_USER' created"

    if [[ -n "$GRAFANA_IP" ]]; then
        if command -v ufw &>/dev/null; then
            ufw allow from "$GRAFANA_IP" to any port 3306 comment "Grafana MySQL RO" 2>/dev/null
            log_info "UFW rule added: $GRAFANA_IP → port 3306"
            log_warn "Block all other external MySQL access:"
            log_warn "  ufw deny 3306"
        else
            log_warn "ufw not found. Add iptables rules manually:"
            log_warn "  iptables -A INPUT -p tcp --dport 3306 -s $GRAFANA_IP -j ACCEPT"
            log_warn "  iptables -A INPUT -p tcp --dport 3306 -j DROP"
        fi
    fi
}

# ─── Final start + summary ───────────────────────────────────
step_finish() {
    log_step "Starting Marzban"
    cd "$MARZBAN_DIR"
    docker compose up -d marzban
    sleep 8

    if docker compose ps marzban 2>/dev/null | grep -q "Up\|running"; then
        log_info "Marzban is running ✓"
    else
        log_warn "Marzban may have failed to start. Check: docker compose logs marzban -f"
    fi

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║          Migration Complete ✓               ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}MySQL credentials:${NC}"
    echo -e "  Root:        ${CYAN}root${NC} / ${CYAN}$MYSQL_ROOT_PASSWORD${NC}"
    echo -e "  Marzban:     ${CYAN}$MYSQL_MARZBAN_USER${NC} / ${CYAN}$MYSQL_MARZBAN_PASSWORD${NC}"
    echo -e "  Grafana RO:  ${CYAN}$MYSQL_GRAFANA_USER${NC} / ${CYAN}$MYSQL_GRAFANA_PASSWORD${NC}"
    echo ""
    echo -e "${BOLD}Grafana → MySQL datasource:${NC}"
    echo -e "  Host:      ${CYAN}<server-ip>:3306${NC}"
    echo -e "  Database:  ${CYAN}$MYSQL_DATABASE${NC}"
    echo -e "  User:      ${CYAN}$MYSQL_GRAFANA_USER${NC}"
    echo -e "  Password:  ${CYAN}$MYSQL_GRAFANA_PASSWORD${NC}"
    echo ""
    echo -e "${BOLD}Credentials saved to:${NC} ${CYAN}$BACKUP_DIR/mysql-credentials.txt${NC}"
    echo -e "${BOLD}Old data backup:${NC}      ${CYAN}$BACKUP_DIR${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "  1. Login to Marzban panel — verify users are present"
    echo -e "  2. Admin → Nodes — reconnect all nodes"
    echo -e "  3. Add MySQL datasource in Grafana"
    [[ -n "$GRAFANA_IP" ]] && echo -e "  4. Run: ${CYAN}ufw deny 3306${NC}  (blocks all except $GRAFANA_IP)"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────
main() {
    preflight
    configure
    gen_passwords
    step_backup
    step_stop_marzban
    step_dump_sqlite
    step_update_compose
    step_update_env
    step_init_mysql
    step_import_data
    step_grafana_setup
    step_finish
}

main
