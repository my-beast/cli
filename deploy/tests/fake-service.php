<?php

declare(strict_types=1);

/*
 * A stand-in for My Beast Deploys' API, for tests/run.sh: `php -S 127.0.0.1:<port> fake-service.php` with
 * FAKE_STATE=<folder>. It answers as routes/api.php does (flat JSON, plain slashes) and writes down what it was sent:
 * started.json (the form), log (the bytes kept, by offset), finished.json, requests (one line per call). A file in
 * the folder changes how it behaves:
 *   down             every call answers 503
 *   lose-lines-once  the first batch is kept, but answered 500 (the answer lost on the way)
 *   app.json         the answer to GET /api/v1/apps/{app}
 */

$state = getenv('FAKE_STATE') ?: sys_get_temp_dir();
$method = $_SERVER['REQUEST_METHOD'];
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$key = 'sk_testkey000000001.secret-secret-secret-secret-secret-secret-123';

$answer = function (int $status, array $body): never {
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
};

file_put_contents("$state/requests", "$method $path ".($_SERVER['QUERY_STRING'] ?? '')."\n", FILE_APPEND);

if (is_file("$state/down")) {
    $answer(503, ['message' => 'down for the test']);
}

if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== "Bearer $key") {
    $answer(401, ['message' => 'unauthenticated']);
}

$id = '01a17d00-0000-7000-8000-000000000001';
$url = 'http://deploys.test/projects/p/apps/demo/deploys/1';

if ($method === 'POST' && $path === '/api/v1/deploys') {
    file_put_contents("$state/started.json", json_encode($_POST, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    touch("$state/log");
    $answer(201, ['id' => $id, 'number' => 1, 'title' => ($_POST['kind'] ?? '') === 'rollback' ? 'Rollback #1' : 'Deploy #1', 'app' => $_POST['app'] ?? '',
        'environment' => $_POST['environment'] ?? '', 'kind' => $_POST['kind'] ?? '', 'status' => 'running', 'url' => $url,
        'warning' => is_file("$state/warn") ? 'Deploy #0 by "Bo" is still running here (started 1 minute ago).' : null]);
}

if ($method === 'POST' && $path === "/api/v1/deploys/$id/lines") {
    $log = (string) @file_get_contents("$state/log");
    $offset = (int) ($_GET['offset'] ?? -1);
    $bytes = (string) file_get_contents('php://input');

    if (is_file("$state/finished.json")) {
        $answer(409, ['message' => 'ended', 'expected' => strlen($log)]);
    }
    if ($offset > strlen($log) || $offset < 0) {
        $answer(409, ['message' => 'gap', 'expected' => strlen($log)]);
    }

    $fresh = substr($bytes, strlen($log) - $offset);
    file_put_contents("$state/log", $fresh, FILE_APPEND);
    file_put_contents("$state/batches", strlen($bytes)."\n", FILE_APPEND);

    if (is_file("$state/lose-lines-once")) {
        unlink("$state/lose-lines-once");
        $answer(500, ['message' => 'the answer was lost']);
    }

    $answer(200, ['received' => strlen($log) + strlen($fresh), 'lines' => substr_count($log.$fresh, "\n"), 'status' => 'running']);
}

if ($method === 'POST' && $path === "/api/v1/deploys/$id/finish") {
    file_put_contents("$state/finished.json", json_encode($_POST, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT));
    $status = $_POST['status'] ?? '';
    $answer(200, ['id' => $id, 'number' => 1, 'title' => 'Deploy #1', 'status' => $status, 'url' => $url, 'release' => $_POST['release'] ?? 'abc123', 'took' => '3s']);
}

if ($method === 'GET' && preg_match('#^/api/v1/apps/([a-z0-9-]+)$#', $path, $m)) {
    if (! is_file("$state/app.json")) {
        $answer(404, ['message' => "No app \"{$m[1]}\" in this project yet: its first deploy adds it."]);
    }
    http_response_code(200);
    header('Content-Type: application/json');
    readfile("$state/app.json");
    exit;
}

$answer(404, ['message' => 'no such route in the fake']);
