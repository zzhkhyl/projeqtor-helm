#!/usr/bin/env bash
#
# ProjeQtOr container entrypoint.
#
# Responsibilities:
#   1. Make sure the writable directories under files/ exist (a freshly
#      attached volume hides the ones baked into the image), including the PHP
#      session directory, which is denied over HTTP. Sessions are kept on the
#      volume on purpose: see docs/known-issues.md (issue P4).
#   2. Generate files/config/parameters.php from the PQ_DB_* environment
#      variables when no configuration exists yet. An existing file is never
#      overwritten, so `helm upgrade` keeps a working configuration. The file
#      also carries the global parameters ProjeQtOr requires to boot at all
#      (logFile, logLevel - see step 2), and a file written by an older release
#      of this image is repaired in place instead of being ignored.
#   3. Create tool/parametersLocation.php pointing to the parameters file
#      (same file the web installer would create).
#   4. Run the PostgreSQL startup data repair, a workaround for an upstream
#      defect in the V13.0.1 upgrade script (see docs/known-issues.md, P1).
#      Idempotent and non-fatal: disable with PQ_PG_REPAIR=false.
#   5. Hand over to the container command (apache2-foreground).
#
# The generated file uses the exact variable names read by ProjeQtOr
# (Parameter::getGlobalParameter() reads the same-named PHP globals).

set -euo pipefail

APP_ROOT="${APP_ROOT:-/var/www/html}"
PARAMETERS_FILE="${PARAMETERS_FILE:-${APP_ROOT}/files/config/parameters.php}"
LOCATION_FILE="${APP_ROOT}/tool/parametersLocation.php"

log() { printf '[projeqtor-entrypoint] %s\n' "$*"; }

export TZ="${TZ:-UTC}"

# Escape a value for embedding inside a single-quoted PHP string.
php_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"
}

# --- 1. Writable directories -------------------------------------------------
for dir in attach config logs report images thumbs import cron session; do
    mkdir -p "${APP_ROOT}/files/${dir}" || log "WARNING: cannot create files/${dir}"
done

# --- 1b. Keep the session directory out of reach over HTTP --------------------
# session.save_path points here (see the Dockerfile). PHP reads and writes these
# files through the filesystem, so denying HTTP access costs nothing. The base
# image already sets "Options -Indexes" for /var/www/, this additionally blocks
# direct requests to a known session file name.
if [ -d "${APP_ROOT}/files/session" ] && [ ! -f "${APP_ROOT}/files/session/.htaccess" ]; then
    printf 'Require all denied\n' > "${APP_ROOT}/files/session/.htaccess" \
        || log "WARNING: cannot write files/session/.htaccess"
fi

# --- 2. Database configuration from environment ------------------------------
#
# Two of the parameters written below are not about the database at all, but
# ProjeQtOr cannot start without them.
#
# tool/projeqtor.php runs scriptLog() on every request, which reaches
# logTracing() (tool/projeqtor.php:3248-3251):
#
#     $logFile=Parameter::getGlobalParameter('logFile');
#     if (!$logFile or $logFile=='' or $level==9) {
#       exit();
#     }
#
# On a database that has never been initialised there is no 'parameter' table
# to read 'logFile' from, so the value has to come from this file. If it does
# not, every request aborts with HTTP 200 and a 0-byte body - before the login
# page, and therefore before the database installation that login triggers, can
# ever be reached. The web installer writes both entries
# (tool/config.php:331,338 - both are mandatory there); this script must emit
# exactly the same contract.
PARAM_LOG_FILE="${PQ_LOG_FILE:-}"
if [ -z "${PARAM_LOG_FILE}" ]; then
    # Single-quoted on purpose. The literal '${date}' placeholder must reach
    # ProjeQtOr untouched (logTracing replaces it with the current date), and
    # nesting it inside a ${VAR:-...} default makes bash close the braces at the
    # wrong place ('projeqtor_${date.log}').
    PARAM_LOG_FILE='../files/logs/projeqtor_${date}.log'
fi
PARAM_LOG_LEVEL="${PQ_LOG_LEVEL:-2}"

write_parameters_file() {
    mkdir -p "$(dirname "${PARAMETERS_FILE}")"
    {
        printf '<?php\n'
        printf '// =======================================================================================\n'
        printf '// Automatically generated parameter file (docker-entrypoint.sh)\n'
        printf '// =======================================================================================\n'
        printf "\$paramDbType = '%s';\n"     "$(php_escape "${PQ_DB_TYPE:-mysql}")"
        printf "\$paramDbHost = '%s';\n"     "$(php_escape "${PQ_DB_HOST}")"
        printf "\$paramDbPort = '%s';\n"     "$(php_escape "${PQ_DB_PORT:-3306}")"
        printf "\$paramDbName = '%s';\n"     "$(php_escape "${PQ_DB_NAME:-projeqtor}")"
        printf "\$paramDbUser = '%s';\n"     "$(php_escape "${PQ_DB_USER:-projeqtor}")"
        printf "\$paramDbPassword = '%s';\n" "$(php_escape "${PQ_DB_PASSWORD:-}")"
        printf "\$paramDbPrefix = '%s';\n"   "$(php_escape "${PQ_DB_PREFIX:-}")"
        printf "\$logFile = '%s';\n"         "$(php_escape "${PARAM_LOG_FILE}")"
        printf "\$logLevel = '%s';\n"        "$(php_escape "${PARAM_LOG_LEVEL}")"
    } > "${PARAMETERS_FILE}"
}

# Add one global parameter when the file does not define it yet. Older releases
# of this image wrote only the $paramDb* entries, and the file is
# never overwritten, so an upgraded deployment keeps the incomplete version and
# would still show the 0-byte symptom. Never touch a file that closes its PHP
# block - appending there would silently produce dead code.
ensure_parameters_key() {
    _key="$1"
    _line="$2"
    if grep -qE '^[[:space:]]*\$'"${_key}"'[[:space:]]*=' "${PARAMETERS_FILE}"; then
        return 0
    fi
    if grep -q '[?]>' "${PARAMETERS_FILE}"; then
        log "WARNING: ${PARAMETERS_FILE} closes its PHP block - cannot add \$${_key} automatically"
        return 0
    fi
    printf '%s\n' "${_line}" >> "${PARAMETERS_FILE}"
    log "Repaired ${PARAMETERS_FILE}: added missing \$${_key}"
}

if [ -f "${PARAMETERS_FILE}" ]; then
    log "Using existing ${PARAMETERS_FILE}"
    ensure_parameters_key logFile  "\$logFile = '$(php_escape "${PARAM_LOG_FILE}")';"
    ensure_parameters_key logLevel "\$logLevel = '$(php_escape "${PARAM_LOG_LEVEL}")';"
elif [ -n "${PQ_DB_HOST:-}" ]; then
    log "Generating ${PARAMETERS_FILE} from PQ_DB_* environment variables"
    write_parameters_file
else
    log "PQ_DB_HOST is not set - the web installation wizard will be used on first access"
fi

# --- 3. Point ProjeQtOr to the parameters file --------------------------------
if [ -f "${PARAMETERS_FILE}" ] && [ ! -f "${LOCATION_FILE}" ]; then
    mkdir -p "$(dirname "${LOCATION_FILE}")"
    {
        printf '<?php\n'
        printf "\$parametersLocation = '%s';\n" "${PARAMETERS_FILE}"
    } > "${LOCATION_FILE}"
fi

# --- 4. PostgreSQL startup data repair -----------------------------------------
# Workaround for an upstream defect: the V13.0.1 upgrade script uses a MySQL-only
# multi-table UPDATE that PostgreSQL cannot execute, so the intended backfill of
# subtask.idProject is silently skipped (docs/known-issues.md, issue P1). The
# script is idempotent and exits 0 even when it cannot repair anything.
if [ "${PQ_PG_REPAIR:-true}" = "true" ] && [ -f /usr/local/bin/projeqtor-pg-repair.php ]; then
    php /usr/local/bin/projeqtor-pg-repair.php || log "WARNING: PostgreSQL data repair failed (non-fatal)"
fi

# --- 5. Start the application --------------------------------------------------
exec "$@"
