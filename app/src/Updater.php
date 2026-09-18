<?php

declare(strict_types=1);

namespace App;

use DateTimeImmutable;
use DateTimeZone;
use RuntimeException;

/**
 * POST /update の本体: JSON を読み → 更新 → 書き戻し → S3 へ PUT する。
 *
 * 二重送信（ダブルクリック、再読み込み）で同一インスタンス内に並行リクエストが来ても更新が失われないよう、
 * read-modify-write から S3 PUT までを 1 つのロック（/tmp のロックファイルに flock）で直列化する（Issue #8、docs/06）。
 * ロックは同一インスタンス内でのみ効くが、max-instances=1 なのでそれで足りる。
 * 一人で操作する前提なので、2 回目の送信を拒否するのではなく順に適用する（counter は 2 回分進む）。
 */
final class Updater
{
    public function __construct(
        private readonly Config $config,
        private readonly JsonStore $store,
        private readonly S3Uploader $uploader,
    ) {
    }

    /**
     * 1 件更新して S3 にアップロードし、各段階の所要時間（ms）などを返す。
     *
     * @return array{lock_wait_ms: float, read_ms: float, write_ms: float, put_ms: float, bytes: int, etag: string, counter: int}
     */
    public function update(string $key, string $value): array
    {
        $lock = fopen($this->lockPath(), 'c');
        if ($lock === false) {
            throw new RuntimeException(sprintf('ロックファイルを開けません: %s', $this->lockPath()));
        }

        try {
            $t0 = hrtime(true);
            if (!flock($lock, LOCK_EX)) {
                throw new RuntimeException('更新のロックを取得できません');
            }
            $t1 = hrtime(true);

            $data = $this->store->read();
            $t2 = hrtime(true);

            $data[$key] = $value;
            $counter = (int) ($data['counter'] ?? 0) + 1;
            $data['counter'] = $counter;
            $data['updated_at'] = (new DateTimeImmutable('now', new DateTimeZone('UTC')))->format(DATE_ATOM);

            $this->store->write($data);
            $t3 = hrtime(true);
            // 大きな JSON（数十 MB）でも memory_limit に収まるよう、PUT の前に配列を手放し、本文はファイルのストリームで渡す
            unset($data);

            $path = $this->config->dataPath();
            clearstatcache(true, $path);
            $bytes = filesize($path);
            $body = fopen($path, 'r');
            if ($bytes === false || $body === false) {
                throw new RuntimeException(sprintf('書き戻した JSON を開けません: %s', $path));
            }
            try {
                $etag = $this->uploader->put($body, $bytes);
            } finally {
                fclose($body);
            }
            $t4 = hrtime(true);

            return [
                'lock_wait_ms' => round(($t1 - $t0) / 1e6, 1),
                'read_ms' => round(($t2 - $t1) / 1e6, 1),
                'write_ms' => round(($t3 - $t2) / 1e6, 1),
                'put_ms' => round(($t4 - $t3) / 1e6, 1),
                'bytes' => $bytes,
                'etag' => $etag,
                'counter' => $counter,
            ];
        } finally {
            // ロックはハンドルを閉じれば解放される
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    /**
     * ロックファイルの場所。/tmp はインスタンス単位（Cloud Run ではインメモリ）なので、消えても次のリクエストで作り直される。
     * gcsfuse 上に置いても他インスタンスには伝播しないので（docs/01 §4）、バケットを汚さない /tmp を使う。
     */
    private function lockPath(): string
    {
        return sys_get_temp_dir() . '/update-' . md5($this->config->dataPath()) . '.lock';
    }
}
