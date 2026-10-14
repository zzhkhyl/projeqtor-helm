<?php
/**
 * ProjeQtOr on PostgreSQL - startup data repair for a known upstream defect.
 *
 * Background (see docs/known-issues.md, issue P1)
 * -----------------------------------------------
 * The upstream upgrade script db/projeqtor_V13.0.1.sql backfills subtask.idProject
 * with three MySQL-only multi-table UPDATE statements:
 *
 *     UPDATE `${prefix}subtask` s LEFT JOIN `${prefix}userstory` a ON ... SET s.idProject = a.idProject WHERE ...;
 *
 * On PostgreSQL, ProjeQtOr runs the very same version scripts and translates the
 * MySQL dialect on the fly (db/maintenanceFunctions.php: formatForDbType()), but
 * that translator has no rule for multi-table UPDATE.  The three statements are
 * therefore sent verbatim to PostgreSQL, fail with a syntax error and the intended
 * backfill is silently skipped (the upgrade itself continues and completes).
 *
 * What this script does
 * ---------------------
 * It performs exactly the same backfill, expressed in PostgreSQL syntax:
 * subtask.idProject is realigned with the idProject of the parent UserStory /
 * Activity / Ticket it refers to (via refType/refId).
 *
 * Guarantees
 * ----------
 * - idempotent     : rows that are already consistent are never touched, so a
 *                    second run updates 0 rows;
 * - non-invasive   : it only issues UPDATE statements, never creates, alters or
 *                    drops anything, and leaves orphan rows (parent object
 *                    missing) and NULL idProject untouched, matching upstream
 *                    semantics (`<>` in SQL);
 * - non-blocking   : every failure mode (no configuration, unsupported database
 *                    type, unreachable database, tables not created yet) is
 *                    reported as a warning and the exit code stays 0, so the
 *                    container always starts.
 *
 * It is invoked by docker-entrypoint.sh before Apache is started and can be
 * disabled with PQ_PG_REPAIR=false.
 */

declare(strict_types=1);

const REPAIR_LOG_PREFIX = '[projeqtor-pg-repair]';

function repairLog(string $message): void
{
    fwrite(STDOUT, REPAIR_LOG_PREFIX . ' ' . $message . PHP_EOL);
}

function repairWarn(string $message): void
{
    fwrite(STDERR, REPAIR_LOG_PREFIX . ' WARNING: ' . $message . PHP_EOL);
}

// --- Configuration: the very same variables the application itself reads --------
$parametersFile = getenv('PARAMETERS_FILE') ?: '/var/www/html/files/config/parameters.php';
if (!is_file($parametersFile)) {
    repairLog("no parameters file at {$parametersFile} - skipped");
    exit(0);
}

$paramDbType = $paramDbHost = $paramDbPort = $paramDbName = $paramDbUser = $paramDbPassword = $paramDbPrefix = null;
require $parametersFile;

if (strtolower((string)$paramDbType) !== 'pgsql') {
    repairLog('database type is "' . (string)$paramDbType . '" - skipped (PostgreSQL only)');
    exit(0);
}
if ((string)$paramDbHost === '') {
    repairLog('no database host configured - skipped');
    exit(0);
}

$prefix = (string)$paramDbPrefix;
$dsn = sprintf(
    'pgsql:host=%s;port=%s;dbname=%s;connect_timeout=10',
    $paramDbHost,
    ((string)$paramDbPort === '') ? '5432' : $paramDbPort,
    (string)$paramDbName
);

try {
    $pdo = new PDO($dsn, (string)$paramDbUser, (string)$paramDbPassword, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
} catch (Throwable $e) {
    repairWarn('cannot connect to PostgreSQL (' . $e->getMessage() . ') - skipped');
    exit(0);
}

// --- The repair needs four tables to exist (they may not, on a brand new install)
$requiredTables = ['subtask', 'userstory', 'activity', 'ticket'];
$missing = [];
$checkTable = $pdo->prepare(
    'SELECT count(*) FROM information_schema.tables'
    . ' WHERE table_schema = current_schema() AND table_name = :table'
);
foreach ($requiredTables as $table) {
    $checkTable->execute([':table' => $prefix . $table]);
    if ((int)$checkTable->fetchColumn() === 0) {
        $missing[] = $prefix . $table;
    }
}
if ($missing !== []) {
    repairLog('table(s) not created yet (' . implode(', ', $missing) . ') - skipped');
    exit(0);
}

// --- Same intent as db/projeqtor_V13.0.1.sql:11-13, in PostgreSQL syntax ---------
$statements = [
    'UserStory' => "UPDATE {$prefix}subtask s SET idProject = a.idProject FROM {$prefix}userstory a"
        . " WHERE s.refType = 'UserStory' AND s.refId = a.id AND s.idProject <> a.idProject",
    'Activity'  => "UPDATE {$prefix}subtask s SET idProject = a.idProject FROM {$prefix}activity a"
        . " WHERE s.refType = 'Activity' AND s.refId = a.id AND s.idProject <> a.idProject",
    'Ticket'    => "UPDATE {$prefix}subtask s SET idProject = a.idProject FROM {$prefix}ticket a"
        . " WHERE s.refType = 'Ticket' AND s.refId = a.id AND s.idProject <> a.idProject",
];

$repaired = 0;
try {
    $pdo->beginTransaction();
    foreach ($statements as $refType => $sql) {
        $affected = $pdo->exec($sql);
        $repaired += (int)$affected;
        repairLog(sprintf('%s: %d row(s) realigned', $refType, (int)$affected));
    }
    $pdo->commit();
} catch (Throwable $e) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
    repairWarn('repair failed (' . $e->getMessage() . ') - the application will start anyway');
    exit(0);
}

repairLog(
    $repaired > 0
        ? "done: {$repaired} subtask row(s) realigned with their parent object"
        : 'done: nothing to repair (subtask.idProject is already consistent)'
);
exit(0);
