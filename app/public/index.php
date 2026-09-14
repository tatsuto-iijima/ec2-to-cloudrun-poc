<?php

declare(strict_types=1);

/**
 * フロントコントローラ。
 *
 * ルーティング:
 *   GET  /        JSON の現在値を表示し、更新フォームを出す
 *   POST /update  JSON を更新して書き戻し、S3 へアップロードする
 *   GET  /healthz 死活確認（ファイルにも S3 にも触らない）
 *
 * Apache では FallbackResource で、PHP 内蔵サーバーではルータースクリプトとして、すべてのパスがここに来る。
 */

use App\Config;
use App\JsonStore;
use App\S3Uploader;

require __DIR__ . '/../vendor/autoload.php';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';

// 死活確認は設定の読み込み前に返す（環境変数の不備でヘルスチェックまで落ちないように）
if ($method === 'GET' && $path === '/healthz') {
    header('Content-Type: application/json');
    echo json_encode(['status' => 'ok']) . "\n";
    exit;
}

try {
    $config = Config::fromEnv();
    $store = new JsonStore($config);

    if ($method === 'GET' && $path === '/') {
        $data = $store->read();
        $result = isset($_GET['result']) ? (string) $_GET['result'] : null;
        $error = isset($_GET['error']) ? (string) $_GET['error'] : null;
        require __DIR__ . '/../templates/index.php';
        exit;
    }

    if ($method === 'POST' && $path === '/update') {
        $key = trim((string) ($_POST['key'] ?? ''));
        $value = (string) ($_POST['value'] ?? '');

        // キーは英数字・記号少々に限定し、値の長さも抑える（PoC の範囲での最低限の入力検証）
        if (!preg_match('/\A[A-Za-z0-9_.-]{1,64}\z/', $key)) {
            redirect('/?error=' . rawurlencode('key は英数字・_ . - の 1〜64 文字で指定してください'));
        }
        if (strlen($value) > 10000) {
            redirect('/?error=' . rawurlencode('value が長すぎます（10000 バイトまで）'));
        }

        // 読み → 更新 → 書き戻し → S3 へ PUT。各段階の所要時間をログに残す（#7 #8 の計測に使う）
        $t0 = hrtime(true);
        $data = $store->read();
        $t1 = hrtime(true);

        $data[$key] = $value;
        $data['counter'] = (int) ($data['counter'] ?? 0) + 1;
        $data['updated_at'] = (new DateTimeImmutable('now', new DateTimeZone('UTC')))->format(DATE_ATOM);

        $store->write($data);
        $t2 = hrtime(true);

        $uploader = new S3Uploader($config);
        $etag = $uploader->put(file_get_contents($config->dataPath()) ?: '');
        $t3 = hrtime(true);

        error_log(sprintf(
            'update key=%s mode=%s read=%.1fms write=%.1fms put=%.1fms target=%s etag=%s',
            $key,
            $config->writeMode,
            ($t1 - $t0) / 1e6,
            ($t2 - $t1) / 1e6,
            ($t3 - $t2) / 1e6,
            $uploader->targetUri(),
            $etag
        ));

        redirect('/?result=' . rawurlencode(sprintf(
            '%s を更新し、%s へアップロードしました（read %.1fms / write %.1fms / put %.1fms）',
            $key,
            $uploader->targetUri(),
            ($t1 - $t0) / 1e6,
            ($t2 - $t1) / 1e6,
            ($t3 - $t2) / 1e6
        )));
    }

    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Not Found\n";
} catch (Throwable $e) {
    // 失敗内容はログに残し、画面には要約だけ出す
    error_log(sprintf('error %s: %s', $e::class, $e->getMessage()));
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Internal Server Error: ' . $e->getMessage() . "\n";
}

/**
 * 303 でリダイレクトして処理を終える。
 */
function redirect(string $location): never
{
    http_response_code(303);
    header('Location: ' . $location);
    exit;
}
