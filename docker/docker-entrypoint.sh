#!/usr/bin/env bash
#
# ProjeQtOr container entrypoint.
#
# Responsibilities:
#   1. Make sure the writable directories under files/ exist (a freshly
#      attached volume hides the ones baked into the image).
#   2. Generate files/config/parameters.php from the PQ_DB_* environment
#      variables when no configuration exists yet. An existing file is never
#      overwritten, so `helm upgrade` keeps a working configuration.
#   3. Create tool/parametersLocation.php pointing to the parameters file
#      (same file the web installer would create).
#   4. Hand over to the container command (apache2-foreground).
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
for dir in attach config logs report images thumbs import cron; do
    mkdir -p "${APP_ROOT}/files/${dir}" || log "WARNING: cannot create files/${dir}"
done

# --- 2. Database configuration from environment ------------------------------
if [ -f "${PARAMETERS_FILE}" ]; then
    log "Using existing ${PARAMETERS_FILE}"
elif [ -n "${PQ_DB_HOST:-}" ]; then
    log "Generating ${PARAMETERS_FILE} from PQ_DB_* environment variables"
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
    } > "${PARAMETERS_FILE}"
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

# --- 4. Start the application --------------------------------------------------
exec "$@"
