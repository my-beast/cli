<?php

declare(strict_types=1);

/*
 * A stand-in for My Beast Vulnerabilities' API, for tests/run.sh: `php -S 127.0.0.1:<port> fake-service.php` with
 * FAKE_STATE=<folder>. It answers as App\Vulnerabilities\Controllers\Api\InventoryController does (flat JSON but for
 * `findings`, plain slashes) and writes down what it was sent: fields.json (the form), files/<field> (each file as
 * it arrived, its name in names.json), headers.json, requests (one line per call). A file in the folder changes it:
 *   down          every call answers 503
 *   refuse        a push answers 422 with this file's text as the message
 *   findings.json the counts it answers with ({"critical": 0, …}); none open without it
 */

$state = getenv('FAKE_STATE') ?: sys_get_temp_dir();
$method = $_SERVER['REQUEST_METHOD'];
$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
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

$findings = is_file("$state/findings.json")
    ? json_decode((string) file_get_contents("$state/findings.json"), true)
    : ['critical' => 0, 'high' => 0, 'medium' => 0, 'low' => 0, 'unrated' => 0];
$report = is_file("$state/report.txt") ? rtrim((string) file_get_contents("$state/report.txt"), "\n") : '';

if ($method === 'POST' && $path === '/api/v1/inventories') {
    file_put_contents("$state/fields.json", json_encode($_POST, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT));
    @mkdir("$state/files");
    $names = [];

    foreach ($_FILES as $kind => $sent) {
        foreach ($sent['tmp_name'] as $i => $parts) {
            foreach ($parts as $part => $tmp) {
                copy($tmp, "$state/files/{$kind}-{$i}-{$part}");
                $names["{$kind}-{$i}-{$part}"] = $sent['name'][$i][$part];
            }
        }
    }

    file_put_contents("$state/names.json", json_encode($names, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT));

    if (is_file("$state/refuse")) {
        $answer(422, ['message' => trim((string) file_get_contents("$state/refuse"))]);
    }

    $answer(201, ['app' => $_POST['app'] ?? '', 'environment' => $_POST['environment'] ?? '', 'inventory' => 7, 'commit' => $_POST['commit'] ?? null,
        'packages' => 417, 'findings' => $findings, 'new' => 2, 'fixed' => 1,
        'url' => 'http://vulnerabilities.test/projects/p/apps/'.($_POST['app'] ?? '').'/'.($_POST['environment'] ?? ''), 'report' => $report]);
}

if ($method === 'GET' && preg_match('#^/api/v1/apps/([a-z0-9-]+)$#', $path, $m)) {
    if (($_GET['environment'] ?? '') !== 'production') {
        $answer(404, ['message' => "{$m[1]} has pushed nothing to ".($_GET['environment'] ?? '')." yet."]);
    }

    $answer(200, ['app' => $m[1], 'environment' => 'production', 'inventory' => 7, 'commit' => 'abcdef1234567890', 'pushed_at' => '2026-10-27T12:00:00+00:00',
        'packages' => 417, 'findings' => $findings, 'url' => "http://vulnerabilities.test/projects/p/apps/{$m[1]}/production", 'report' => $report]);
}

$answer(404, ['message' => 'no such route in the fake']);
