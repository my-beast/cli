<?php

declare(strict_types=1);

/*
 * A stand-in for My Beast Translations' strings API, for tests/run.sh: `php -S 127.0.0.1:<port> fake-service.php`
 * with FAKE_STATE=<folder> and FAKE_FIXTURES=<tests/fixtures>. It answers a call that accepts text/plain as
 * App\Translations\Controllers\Api\Plain does (the fixtures, rendered by services: fixtures/render.php) and writes
 * down what it was sent: start.json (a push's first call), sent/<n>.json (each file as it arrived, opened when it
 * came as gzip) with sent/<n>.query, requests (one line per call), accept (the last Accept header). A file in the
 * state folder changes it:
 *   down           every call answers 503
 *   finish         the fixture a finish answers with (default: pushed, or checked-ok for a check)
 *   refuse-file    a file is refused, 422, with this file's text
 *   refuse-finish  a finish is refused, 422, with this file's text
 *   fills          the fixtures a fill answers with, one a line, each call the next (the last one stays)
 *   no-files       the project has no files yet
 *   nothing-served a pulled file holds no words in any language
 */

$state = getenv('FAKE_STATE') ?: sys_get_temp_dir();
$fixtures = getenv('FAKE_FIXTURES') ?: __DIR__.'/fixtures';
$method = $_SERVER['REQUEST_METHOD'];
$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$key = 'sk_testkey000000001.secret-secret-secret-secret-secret-secret-123';
$push = '0b7d6a1c-6f0e-4a0b-9d6e-2f8a5c3e1b47';

$plain = function (int $status, string $text): never {
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    echo rtrim($text, "\n")."\n";
    exit;
};
$json = function (int $status, array $body): never {
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
};
$fixture = fn (string $name): string => (string) file_get_contents("{$fixtures}/{$name}.txt");

file_put_contents("$state/requests", "$method $path ".($_SERVER['QUERY_STRING'] ?? '')."\n", FILE_APPEND);
file_put_contents("$state/accept", $_SERVER['HTTP_ACCEPT'] ?? '');

if (is_file("$state/down")) {
    $json(503, ['message' => 'down for the test']);
}

if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== "Bearer $key") {
    $json(401, ['message' => 'Unauthenticated.']);
}

if ($method === 'POST' && $path === '/api/v1/strings/pushes') {
    file_put_contents("$state/start.json", (string) file_get_contents('php://input'));
    $plain(201, $push);
}

if ($method === 'PUT' && $path === "/api/v1/strings/pushes/{$push}/files") {
    if (is_file("$state/refuse-file")) {
        $plain(422, (string) file_get_contents("$state/refuse-file"));
    }

    @mkdir("$state/sent");
    $n = count(glob("$state/sent/*.json") ?: []);
    $body = (string) file_get_contents('php://input');
    $gzip = str_contains(strtolower($_SERVER['HTTP_CONTENT_ENCODING'] ?? ''), 'gzip');
    file_put_contents("$state/sent/{$n}.json", $gzip ? (string) gzdecode($body) : $body);
    file_put_contents("$state/sent/{$n}.query", json_encode($_GET + ['gzip' => $gzip], JSON_UNESCAPED_SLASHES));
    $plain(200, (string) count((array) json_decode($gzip ? (string) gzdecode($body) : $body, true)));
}

if ($method === 'POST' && $path === "/api/v1/strings/pushes/{$push}/finish") {
    if (is_file("$state/refuse-finish")) {
        $plain(422, (string) file_get_contents("$state/refuse-finish"));
    }

    $check = str_contains((string) @file_get_contents("$state/start.json"), '"check":true');
    $plain(200, $fixture(is_file("$state/finish") ? trim((string) file_get_contents("$state/finish")) : ($check ? 'checked-ok' : 'pushed')));
}

if ($method === 'GET' && $path === '/api/v1/strings/files') {
    $plain(200, is_file("$state/no-files") ? '' : $fixture('files'));
}

if ($method === 'GET' && $path === '/api/v1/strings/pull') {
    $words = ['fi' => ['common.hello' => 'Hei {{name}}', 'common.save' => 'Tallenna'], 'sv' => ['common.hello' => 'Hej {{name}}']];
    $language = (string) ($_GET['language'] ?? '');

    if (is_file("$state/nothing-served")) {
        http_response_code(200);
        header('Content-Type: application/json; charset=utf-8');
        echo "{}\n";
        exit;
    }

    if (($_GET['file'] ?? '') !== 'resources/js/locales/{lang}.json' || ! isset($words[$language])) {
        $plain(404, "The project has no file called ".($_GET['file'] ?? '').'.');
    }

    http_response_code(200);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($words[$language], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)."\n";
    exit;
}

if ($method === 'GET' && preg_match('#^/api/v1/strings/fills/(\d+)$#', $path) === 1) {
    $steps = is_file("$state/fills") ? array_values(array_filter(array_map('trim', file("$state/fills") ?: []))) : ['fill-done'];
    $at = (int) @file_get_contents("$state/fill-at");
    file_put_contents("$state/fill-at", (string) ($at + 1));
    $plain(200, $fixture($steps[min($at, count($steps) - 1)]));
}

if ($method === 'GET' && $path === '/api/v1/strings') {
    $plain(200, $fixture('standing'));
}

$json(404, ['message' => 'no such route in the fake']);
