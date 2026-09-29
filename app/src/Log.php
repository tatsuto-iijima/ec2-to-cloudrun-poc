<?php

declare(strict_types=1);

namespace App;

/**
 * アプリのログを stderr に 1 行で書く（Cloud Run では Cloud Logging の run.googleapis.com/stderr に入る）。
 *
 * error_log() は mod_php では Apache の error ログを経由し、Apache が本文の非 ASCII を \xNN にエスケープする
 * （日本語の例外メッセージが読めなくなる。docs/08 §2.1）。php://stderr はプロセスの fd 2（Apache が起動時に開いた
 * コンテナの stderr）を複製して書くので、エスケープされず UTF-8 のまま残る。
 */
final class Log
{
    public static function write(string $message): void
    {
        // 1 行 = 1 エントリにする（改行が入ると Cloud Logging で別のエントリに割れる）。
        // 短い行を 1 回で書くので、prefork の子プロセスが同時に書いても行は混ざらない
        $line = str_replace(["\r\n", "\r", "\n"], ' ', $message) . "\n";
        if (@file_put_contents('php://stderr', $line) === false) {
            error_log($message);
        }
    }
}
