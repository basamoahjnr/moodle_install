<?php  // Moodle configuration file.
unset($CFG);
global $CFG;
$CFG = new stdClass();

$envfile = '/opt/moodle/.env';
if (!is_readable($envfile)) {
    throw new RuntimeException('Moodle environment file is not readable: ' . $envfile);
}

$env = [];
foreach (file($envfile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $line = trim($line);
    if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
        continue;
    }
    [$key, $value] = explode('=', $line, 2);
    $key = trim($key);
    $value = trim($value);
    if ($value !== '' && $value[0] === '"' && substr($value, -1) === '"') {
        $value = stripcslashes(substr($value, 1, -1));
    }
    $env[$key] = $value;
}

foreach (['MOODLE_HOST', 'MOODLE_DB', 'MOODLE_DB_USER', 'MOODLE_DB_PASS'] as $required) {
    if (!array_key_exists($required, $env) || $env[$required] === '') {
        throw new RuntimeException('Missing required Moodle environment value: ' . $required);
    }
}

$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = '127.0.0.1';
$CFG->dbname    = $env['MOODLE_DB'];
$CFG->dbuser    = $env['MOODLE_DB_USER'];
$CFG->dbpass    = $env['MOODLE_DB_PASS'];
$CFG->prefix    = 'mdl_';
$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => '',
];

$CFG->wwwroot   = 'https://' . $env['MOODLE_HOST'];
$CFG->dataroot  = '/var/moodledata';
$CFG->admin     = 'admin';

$CFG->session_handler_class = '\core\session\redis';
$CFG->session_redis_host = '127.0.0.1';
$CFG->session_redis_port = 6379;
$CFG->session_redis_database = 0;
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire = 7200;

$CFG->directorypermissions = 0770;

require_once(__DIR__ . '/lib/setup.php');
