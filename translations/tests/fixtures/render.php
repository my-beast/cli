<?php

declare(strict_types=1);

/*
 * The fixtures as services answers them today: `php render.php <services folder> <out folder>` writes each of
 * answers.json's answers the way App\Translations\Controllers\Api\Plain says it to a call that accepts text/plain.
 * `make sdk-check` (the My Beast folder) runs it and says when the fixtures here have drifted.
 */

use App\Translations\Controllers\Api\Plain;

require $argv[1].'/vendor/autoload.php';

$answers = json_decode((string) file_get_contents(__DIR__.'/answers.json'), true, 512, JSON_THROW_ON_ERROR);

foreach ($answers as $name => $answer) {
    $text = match (true) {
        $name === 'files' => Plain::files($answer),
        $name === 'standing' => Plain::standing($answer),
        str_starts_with($name, 'fill-') => Plain::fill($answer),
        default => Plain::finished($answer),
    };
    file_put_contents($argv[2]."/{$name}.txt", rtrim($text, "\n")."\n");
}
