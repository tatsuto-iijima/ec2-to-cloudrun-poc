<?php

declare(strict_types=1);

/**
 * フロントコントローラ。
 *
 * ルーティング:
 *   GET  /        JSON の現在値を表示し、更新フォームを出す
 *   POST /update  JSON を更新して書き戻し、S3 へアップロードする（Updater。flock で直列化）
 *   GET  /health 死活確認（ファイルにも S3 にも触らない）
 *   POST /fs-check  gcsfuse 検証用の診断（FS_CHECK=1 のときだけ。Issue #7。scripts/fs-check.sh から呼ぶ）
 *
 * Apache では FallbackResource で、PHP 内蔵サーバーではルータースクリプトとして、すべてのパスがここに来る。
 */

use App\Config;
use App\FsCheck;
use App\GoogleWebIdentityCredentialProvider;
use App\JsonStore;
use App\S3Uploader;
use App\Updater;

require __DIR__ . '/../vendor/autoload.php';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';

// 死活確認は設定の読み込み前に返す（環境変数の不備でヘルスチェックまで落ちないように）
if ($method === 'GET' && $path === '/health') {
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

        // 読み → 更新 → 書き戻し → S3 へ PUT（Updater が flock で直列化する。docs/06）。各段階の所要時間をログに残す
        // Cloud Run では SA の ID トークンで AWS の IAM ロールを引き受ける（鍵レス）。ローカル（moto）では SDK の既定チェーン
        $credentials = $config->usesWebIdentity() ? new GoogleWebIdentityCredentialProvider($config) : null;
        $uploader = new S3Uploader($config, $credentials);
        $r = (new Updater($config, $store, $uploader))->update($key, $value);

        error_log(sprintf(
            'update key=%s mode=%s lock=%.1fms read=%.1fms write=%.1fms put=%.1fms bytes=%d counter=%d target=%s etag=%s',
            $key,
            $config->writeMode,
            $r['lock_wait_ms'],
            $r['read_ms'],
            $r['write_ms'],
            $r['put_ms'],
            $r['bytes'],
            $r['counter'],
            $uploader->targetUri(),
            $r['etag']
        ));

        // 所要時間は画面にも出す（scripts/update-bench.sh が Location からこの形式を読み取る）
        redirect('/?result=' . rawurlencode(sprintf(
            '%s を更新し、%s へアップロードしました（read %.1fms / write %.1fms / put %.1fms）',
            $key,
            $uploader->targetUri(),
            $r['read_ms'],
            $r['write_ms'],
            $r['put_ms']
        )));
    }

    // DATA_DIR 上のファイル操作を検証する診断（gcsfuse の挙動を計測する。data.json には触らない）。
    // 無効時は存在しない経路として扱う
    if ($method === 'POST' && $path === '/fs-check' && $config->fsCheckEnabled) {
        $params = array_map(static fn (mixed $v): string => (string) $v, $_POST);
        $case = $params['case'] ?? 'info';
        $result = (new FsCheck($config))->run($case, $params);
        error_log(sprintf('fs-check case=%s ok=%s total=%.1fms', $case, $result['ok'] ? 'true' : 'false', $result['total_ms']));
        header('Content-Type: application/json');
        echo json_encode($result, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
        exit;
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
