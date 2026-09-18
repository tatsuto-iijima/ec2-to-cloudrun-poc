<?php

declare(strict_types=1);

namespace App;

/**
 * このプロセスが動いているインスタンスの識別情報。
 *
 * Cloud Run の /tmp はインスタンス単位のインメモリ FS なので、最初のリクエストで /tmp に乱数と時刻を置けば、
 * 同じインスタンスの間は同じ ID、入れ替わると別の ID になる。全応答に X-Instance-Id / X-Instance-Uptime を付け、
 * コールドスタートの判定（docs/07）と、gcsfuse 検証でのインスタンス入れ替わりの確認（docs/05）に使う。
 * 起動プローブ（GET /health）が最初のリクエストになるので、uptime はプローブ成功からの経過秒数に近い。
 */
final class InstanceInfo
{
    private const FILE = '/tmp/instance-id';

    /** @var array{id: string, started_at: int}|null */
    private static ?array $cached = null;

    /** インスタンスの ID（8 桁の 16 進） */
    public static function id(): string
    {
        return self::load()['id'];
    }

    /** このインスタンスが最初のリクエストを受けてからの秒数 */
    public static function uptimeSeconds(): int
    {
        return max(0, time() - self::load()['started_at']);
    }

    /** 応答ヘッダーを付ける（すべての経路で呼ぶ） */
    public static function sendHeaders(): void
    {
        header('X-Instance-Id: ' . self::id());
        header('X-Instance-Uptime: ' . self::uptimeSeconds());
    }

    /**
     * @return array{id: string, started_at: int}
     */
    private static function load(): array
    {
        if (self::$cached !== null) {
            return self::$cached;
        }

        $raw = @file_get_contents(self::FILE);
        if ($raw !== false && preg_match('/\A([0-9a-f]{8}) (\d+)\z/', trim($raw), $m)) {
            return self::$cached = ['id' => $m[1], 'started_at' => (int) $m[2]];
        }

        // 初回: 乱数と時刻を書く（並行リクエストが同時に来ても、後勝ちで同じインスタンスの値になるだけなので問題ない）
        $info = ['id' => bin2hex(random_bytes(4)), 'started_at' => time()];
        @file_put_contents(self::FILE, sprintf('%s %d', $info['id'], $info['started_at']), LOCK_EX);

        return self::$cached = $info;
    }
}
