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
 *
 * The job's calls (below /api/v1/job, with the job key; a server key there answers 401, and a job key anywhere else)
 * are written down as asked.json (the last ask), job-started.json, refused.json and tested.json, with a line per
 * call in asks, starts and finishes; the run's log and finished.json are kept as above. And they are steered alike:
 *   request.json      fields POST job/ask answers in place of its own: a request ("request", "release", "asked_by",
 *                     "test"), or "app", "environment", "on". The request is handed out until it is started, refused
 *                     or tested (request-closed says which), and never to a check
 *   lose-start        holds a number: that many starts are kept, but answered 500 (the answer lost on the way)
 *   start-409         a start answers 409: the request is no longer this job's
 *   fail-finish-once  the first finish of a job's run is not kept, and answers 500
 */

$state = getenv('FAKE_STATE') ?: sys_get_temp_dir();
$method = $_SERVER['REQUEST_METHOD'];
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$key = 'sk_testkey000000001.secret-secret-secret-secret-secret-secret-123';
$jobKey = 'jk_testkey000000001.secret-secret-secret-secret-secret-secret-123';
$job = str_starts_with((string) $path, '/api/v1/job/');

$answer = function (int $status, array $body): never {
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
};

$keep = function (string $file, array $form) use ($state): void {
    file_put_contents("$state/$file", json_encode($form, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
};

file_put_contents("$state/requests", "$method $path ".($_SERVER['QUERY_STRING'] ?? '')."\n", FILE_APPEND);

if (is_file("$state/down")) {
    $answer(503, ['message' => 'down for the test']);
}

if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== 'Bearer '.($job ? $jobKey : $key)) {
    $answer(401, ['message' => 'unauthenticated']);
}

$id = '01a17d00-0000-7000-8000-000000000001';
$url = 'http://deploys.test/projects/p/apps/demo/deploys/1';
$runs = $job ? '/api/v1/job/deploys' : '/api/v1/deploys';

// What waits for the job, and how it was closed (started, refused, tested) once it was.
$waiting = $job && is_file("$state/request.json") ? (array) json_decode((string) file_get_contents("$state/request.json"), true) : [];
$request = $waiting['request'] ?? null;
$closed = is_file("$state/request-closed") ? trim((string) file_get_contents("$state/request-closed")) : null;

if ($method === 'POST' && $path === '/api/v1/job/ask') {
    $keep('asked.json', $_POST);
    file_put_contents("$state/asks", "ask\n", FILE_APPEND);

    $body = array_merge([
        'app' => 'demo', 'environment' => 'staging', 'project' => 'demo.test', 'on' => true, 'ask_again' => 60,
        'page' => 'http://deploys.test/projects/p/apps/demo/settings/rollback/staging',
        'request' => null, 'release' => null, 'asked_by' => null, 'test' => false,
    ], $waiting);

    if ($closed !== null || ($_POST['check'] ?? '') === '1') {
        $body = array_merge($body, ['request' => null, 'release' => null, 'asked_by' => null, 'test' => false]);
    }

    $answer(200, $body);
}

if ($method === 'POST' && preg_match('#^/api/v1/job/requests/([^/]+)/(start|refuse|tested)$#', (string) $path, $m)) {
    if ($m[1] !== $request) {
        $answer(404, ['message' => 'not found']);
    }

    $test = ($waiting['test'] ?? false) === true;

    if ($m[2] === 'refuse') {
        if ($closed !== null) {
            $answer(409, ['message' => "This request has $closed already."]);
        }
        $keep('refused.json', $_POST + ['request' => $m[1]]);
        file_put_contents("$state/request-closed", 'refused');
        $answer(200, ['request' => $m[1], 'status' => 'refused']);
    }

    if ($m[2] === 'tested') {
        if ($closed !== null || ! $test) {
            $answer(409, ['message' => $test ? "This request has $closed already." : 'This request is no test.']);
        }
        $keep('tested.json', $_POST + ['request' => $m[1]]);
        file_put_contents("$state/request-closed", 'tested');
        $answer(200, ['request' => $m[1], 'status' => 'tested']);
    }

    if (is_file("$state/start-409") || $test || ($closed !== null && $closed !== 'started')) {
        $answer(409, ['message' => $test ? 'A test is not started.' : 'This request is not waiting for this job any more.']);
    }

    // The same request started again answers with the same run: 201 the first time, 200 after.
    $keep('job-started.json', $_POST + ['request' => $m[1]]);
    file_put_contents("$state/starts", "start\n", FILE_APPEND);
    file_put_contents("$state/request-closed", 'started');
    touch("$state/log");

    if (is_file("$state/lose-start")) {
        $left = max(1, (int) file_get_contents("$state/lose-start")) - 1;
        $left > 0 ? file_put_contents("$state/lose-start", (string) $left) : unlink("$state/lose-start");
        $answer(500, ['message' => 'the answer was lost']);
    }

    $answer($closed === null ? 201 : 200, ['id' => $id, 'number' => 1, 'title' => 'Rollback #1', 'app' => 'demo', 'environment' => 'staging',
        'kind' => 'rollback', 'status' => 'running', 'url' => $url, 'release' => $waiting['release'] ?? null,
        'warning' => is_file("$state/warn") ? 'Deploy #0 by "Bo" is still running here (started 1 minute ago).' : null]);
}

// A job's key reaches the runs it started, and no other.
if ($job && ! is_file("$state/job-started.json")) {
    $answer(404, ['message' => 'not found']);
}

if ($method === 'POST' && $path === '/api/v1/deploys') {
    $keep('started.json', $_POST);
    touch("$state/log");
    $answer(201, ['id' => $id, 'number' => 1, 'title' => ($_POST['kind'] ?? '') === 'rollback' ? 'Rollback #1' : 'Deploy #1', 'app' => $_POST['app'] ?? '',
        'environment' => $_POST['environment'] ?? '', 'kind' => $_POST['kind'] ?? '', 'status' => 'running', 'url' => $url,
        'warning' => is_file("$state/warn") ? 'Deploy #0 by "Bo" is still running here (started 1 minute ago).' : null]);
}

if ($method === 'POST' && $path === "$runs/$id/lines") {
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

if ($method === 'POST' && $path === "$runs/$id/finish") {
    if ($job) {
        file_put_contents("$state/finishes", "finish\n", FILE_APPEND);

        if (is_file("$state/fail-finish-once")) {
            unlink("$state/fail-finish-once");
            $answer(500, ['message' => 'not kept, for the test']);
        }
    }

    // The first word stands: a second finish changes nothing.
    if (! is_file("$state/finished.json")) {
        file_put_contents("$state/finished.json", json_encode($_POST, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT));
    }
    $kept = (array) json_decode((string) file_get_contents("$state/finished.json"), true);
    $answer(200, ['id' => $id, 'number' => 1, 'title' => $job ? 'Rollback #1' : 'Deploy #1', 'status' => $kept['status'] ?? '', 'url' => $url,
        'release' => $kept['release'] ?? ($job ? ($waiting['release'] ?? null) : 'abc123'), 'took' => '3s']);
}

if ($method === 'GET' && preg_match('#^/api/v1/apps/([a-z0-9-]+)$#', (string) $path, $m)) {
    if (! is_file("$state/app.json")) {
        $answer(404, ['message' => "No app \"{$m[1]}\" in this project yet: its first deploy adds it."]);
    }
    http_response_code(200);
    header('Content-Type: application/json');
    readfile("$state/app.json");
    exit;
}

$answer(404, ['message' => 'no such route in the fake']);
