<?php

declare(strict_types=1);

namespace App;

use InvalidArgumentException;
use RuntimeException;

/**
 * gcsfuse マウント領域（DATA_DIR）でのファイル操作を検証する診断ロジック（Issue #7）。
 *
 * アプリと同じプロセス（Apache + mod_php、www-data、同じマウント）で測るために、
 * POST /fs-check（FS_CHECK=1 のときだけ有効）から呼ばれる。scripts/fs-check.sh が case を順に呼び出す。
 * 検証用のファイルは DATA_DIR/fs-check/ 配下に置き、data.json には触らない（例外は #8 用の pad case）。
 */
final class FsCheck
{
    /** 検証用ファイルを置くサブディレクトリ */
    private const SUBDIR = 'fs-check';

    /** size パラメータの上限（memory_limit 128M の既定で読み書きできる範囲） */
    private const MAX_SIZE = 64 * 1024 * 1024;

    public function __construct(private readonly Config $config)
    {
    }

    /**
     * 1 つの case を実行し、結果を連想配列で返す。
     *
     * @param array<string, string> $params case ごとのパラメータ（size / n / seconds）
     * @return array<string, mixed>
     */
    public function run(string $case, array $params): array
    {
        $size = $this->intParam($params, 'size', 1024, 0, self::MAX_SIZE);
        $n = $this->intParam($params, 'n', 10, 1, 1000);
        $seconds = $this->intParam($params, 'seconds', 3, 0, 60);
        $interval = $this->intParam($params, 'interval', 100, 0, 1000);

        $started = hrtime(true);
        $result = match ($case) {
            'info' => $this->info(),
            'rmw' => $this->readModifyWrite(),
            'rename' => $this->rename($size),
            'rename-loop' => $this->renameLoop($n, $size, $interval),
            'read-loop' => $this->readLoop($seconds),
            'lock' => $this->lock(),
            'lock-hold' => $this->lockHold($seconds),
            'append' => $this->append($size),
            'size' => $this->size($size),
            'misc' => $this->misc(),
            'pad' => $this->pad($size),
            'cleanup' => $this->cleanup(),
            default => throw new InvalidArgumentException(sprintf('未知の case です: %s', $case)),
        };

        return [
            'case' => $case,
            'ok' => $result['ok'] ?? true,
            'instance' => InstanceInfo::id(),
            'instance_uptime' => InstanceInfo::uptimeSeconds(),
            'revision' => getenv('K_REVISION') ?: null,
            'data_dir' => $this->config->dataDir,
            'write_mode' => $this->config->writeMode,
            'total_ms' => $this->ms($started),
            ...$result,
        ];
    }

    /**
     * 環境の情報。DATA_DIR の状態と実行ユーザーを確認する。
     *
     * @return array<string, mixed>
     */
    private function info(): array
    {
        $dir = $this->config->dataDir;

        return [
            'exists' => is_dir($dir),
            'is_writable' => is_writable($dir),
            'disk_free_bytes' => @disk_free_space($dir) ?: null,
            'uid' => function_exists('posix_geteuid') ? posix_geteuid() : null,
            'gid' => function_exists('posix_getegid') ? posix_getegid() : null,
            'php_version' => PHP_VERSION,
            'sapi' => PHP_SAPI,
            'uname' => php_uname('r'),
            'memory_limit' => ini_get('memory_limit'),
            'mount' => $this->mountLine($dir),
        ];
    }

    /**
     * (a) read-modify-write: 読み → counter++ → LOCK_EX で書き戻し → 読み直して一致確認。
     *
     * @return array<string, mixed>
     */
    private function readModifyWrite(): array
    {
        $path = $this->path('rmw.json');

        $t = hrtime(true);
        $data = $this->readJson($path) ?? ['message' => 'fs-check rmw', 'counter' => 0];
        $readMs = $this->ms($t);

        $data['counter'] = (int) ($data['counter'] ?? 0) + 1;
        $data['updated_at'] = gmdate(DATE_ATOM);
        $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";

        $t = hrtime(true);
        $written = file_put_contents($path, $json, LOCK_EX);
        $writeMs = $this->ms($t);

        $t = hrtime(true);
        $reread = $this->readJson($path);
        $rereadMs = $this->ms($t);

        return [
            'ok' => $written === strlen($json) && $reread === $data,
            'counter' => $data['counter'],
            'written' => $written,
            'reread_matches' => $reread === $data,
            'read_ms' => $readMs,
            'write_ms' => $writeMs,
            'reread_ms' => $rereadMs,
        ];
    }

    /**
     * (b) 一時ファイル + rename による差し替えの所要時間。
     *
     * @return array<string, mixed>
     */
    private function rename(int $size): array
    {
        $path = $this->path('rename.json');
        $tmp = $path . '.' . bin2hex(random_bytes(4)) . '.tmp';
        $json = $this->payload($size, 1);

        $t = hrtime(true);
        $written = file_put_contents($tmp, $json);
        $writeMs = $this->ms($t);

        $t = hrtime(true);
        $renamed = @rename($tmp, $path);
        $renameMs = $this->ms($t);
        $renameError = $renamed ? null : (error_get_last()['message'] ?? 'unknown');

        $t = hrtime(true);
        $read = file_get_contents($path);
        $readMs = $this->ms($t);

        clearstatcache(true, $tmp);

        return [
            'ok' => $written === strlen($json) && $renamed && $read === $json && !file_exists($tmp),
            'size' => strlen($json),
            'written' => $written,
            'renamed' => $renamed,
            'rename_error' => $renameError,
            'tmp_remains' => file_exists($tmp),
            'content_matches' => $read === $json,
            'write_ms' => $writeMs,
            'rename_ms' => $renameMs,
            'read_ms' => $readMs,
        ];
    }

    /**
     * (b) 原子性の書き手: 内容が丸ごと異なる JSON を n 回 tmp + rename で差し替える。read-loop と並行して呼ぶ。
     * interval（ms）だけ間隔を空け、読み手と確実に重なるようにする。
     *
     * @return array<string, mixed>
     */
    private function renameLoop(int $n, int $size, int $interval): array
    {
        $path = $this->path('atomic.json');
        $renameMs = [];
        $failed = 0;

        for ($seq = 1; $seq <= $n; $seq++) {
            if ($seq > 1 && $interval > 0) {
                usleep($interval * 1000);
            }
            $tmp = $path . '.' . bin2hex(random_bytes(4)) . '.tmp';
            file_put_contents($tmp, $this->payload($size, $seq));
            $t = hrtime(true);
            if (!@rename($tmp, $path)) {
                $failed++;
                @unlink($tmp);
            }
            $renameMs[] = $this->ms($t);
        }

        return [
            'ok' => $failed === 0,
            'iterations' => $n,
            'size' => $size,
            'interval_ms' => $interval,
            'failed' => $failed,
            'rename_ms_min' => min($renameMs),
            'rename_ms_avg' => round(array_sum($renameMs) / count($renameMs), 1),
            'rename_ms_max' => max($renameMs),
        ];
    }

    /**
     * (b) 原子性の読み手: seconds 秒間 atomic.json を読み続け、途中の内容（JSON 不正・先頭と末尾の seq 不一致）を数える。
     *
     * @return array<string, mixed>
     */
    private function readLoop(int $seconds): array
    {
        $path = $this->path('atomic.json');
        $deadline = hrtime(true) + $seconds * 1_000_000_000;
        $reads = 0;
        $missingBeforeFirst = 0; // 書き手がまだ 1 回目の rename をしていない間（ファイルが無い）
        $missing = 0;            // 一度読めた後にファイルが無くなった回数（rename 中に消えて見えるか）
        $invalid = 0;
        $torn = 0;
        $seqs = [];

        while (hrtime(true) < $deadline) {
            $reads++;
            $raw = @file_get_contents($path);
            if ($raw === false) {
                if ($seqs === []) {
                    $missingBeforeFirst++;
                } else {
                    $missing++;
                }
                continue;
            }
            $data = json_decode($raw, true);
            if (!is_array($data) || !isset($data['seq'], $data['seq_tail'])) {
                $invalid++;
                continue;
            }
            if ($data['seq'] !== $data['seq_tail']) {
                $torn++;
                continue;
            }
            $seqs[$data['seq']] = true;
        }

        return [
            'ok' => $invalid === 0 && $torn === 0 && $missing === 0,
            'seconds' => $seconds,
            'reads' => $reads,
            'missing_before_first' => $missingBeforeFirst,
            'missing' => $missing,
            'invalid_json' => $invalid,
            'torn' => $torn,
            'distinct_seq' => count($seqs),
        ];
    }

    /**
     * (c) ロック付き書き込みと flock の戻り値。
     *
     * @return array<string, mixed>
     */
    private function lock(): array
    {
        $path = $this->path('lock.json');
        $json = $this->payload(256, 1);

        $t = hrtime(true);
        $written = file_put_contents($path, $json, LOCK_EX);
        $putMs = $this->ms($t);
        $putError = $written === false ? (error_get_last()['message'] ?? 'unknown') : null;

        $fp = fopen($path, 'r+');
        if ($fp === false) {
            return ['ok' => false, 'written' => $written, 'put_error' => $putError, 'fopen' => false];
        }

        $t = hrtime(true);
        $ex = flock($fp, LOCK_EX);
        $flockMs = $this->ms($t);
        // 同じハンドルで再取得（LOCK_NB）。flock はハンドル単位なので true が返るのが通常
        $exNb = flock($fp, LOCK_EX | LOCK_NB);
        $un = flock($fp, LOCK_UN);

        // 別ハンドルからの LOCK_NB: ロック解放後なので取れるはず
        $fp2 = fopen($path, 'r');
        $sh = $fp2 !== false ? flock($fp2, LOCK_SH | LOCK_NB) : null;
        if ($fp2 !== false) {
            flock($fp2, LOCK_UN);
            fclose($fp2);
        }
        fclose($fp);

        return [
            'ok' => $written === strlen($json) && $ex && $un,
            'written' => $written,
            'put_error' => $putError,
            'put_ms' => $putMs,
            'flock_ex' => $ex,
            'flock_ex_nb_same_handle' => $exNb,
            'flock_un' => $un,
            'flock_sh_nb_other_handle' => $sh,
            'flock_ms' => $flockMs,
        ];
    }

    /**
     * (c) 直列化: flock(LOCK_EX) を取るまでの待ち時間を測り、seconds 秒保持してから解放する。
     * 2 リクエストを同時に投げ、後着の wait_ms が先着の保持時間に近ければ同一インスタンス内で直列化されている。
     *
     * @return array<string, mixed>
     */
    private function lockHold(int $seconds): array
    {
        $path = $this->path('hold.lock');
        $fp = fopen($path, 'c+');
        if ($fp === false) {
            return ['ok' => false, 'fopen' => false];
        }

        $t = hrtime(true);
        $locked = flock($fp, LOCK_EX);
        $waitMs = $this->ms($t);
        $acquiredAt = microtime(true);

        if ($locked && $seconds > 0) {
            sleep($seconds);
        }
        $released = flock($fp, LOCK_UN);
        fclose($fp);

        return [
            'ok' => $locked && $released,
            'locked' => $locked,
            'wait_ms' => $waitMs,
            'held_seconds' => $seconds,
            'acquired_at' => $acquiredAt,
            'released' => $released,
        ];
    }

    /**
     * (d) FILE_APPEND による追記の所要時間。
     *
     * @return array<string, mixed>
     */
    private function append(int $size): array
    {
        $path = $this->path('append.log');
        $line = str_repeat('a', max(0, $size - 1)) . "\n";
        clearstatcache(true, $path);
        $before = file_exists($path) ? (filesize($path) ?: 0) : 0;

        $t = hrtime(true);
        $written = file_put_contents($path, $line, FILE_APPEND | LOCK_EX);
        $appendMs = $this->ms($t);

        clearstatcache(true, $path);
        $after = filesize($path) ?: 0;

        return [
            'ok' => $written === strlen($line) && $after === $before + strlen($line),
            'appended' => $written,
            'size_before' => $before,
            'size_after' => $after,
            'append_ms' => $appendMs,
        ];
    }

    /**
     * (f) サイズ別の新規作成 / 上書き（LOCK_EX）/ tmp + rename / 読み込みの所要時間。
     * 大きなサイズ（50MB）でも memory_limit 128M に収まるよう、文字列は使い終えるたびに解放し、内容の比較はハッシュで行う。
     *
     * @return array<string, mixed>
     */
    private function size(int $size): array
    {
        $path = $this->path(sprintf('size-%d.json', $size));

        // 1 回目: 新規作成
        $json = $this->payload($size, 1);
        $t = hrtime(true);
        $created = file_put_contents($path, $json, LOCK_EX);
        $createMs = $this->ms($t);
        unset($json);

        // 2 回目: 既存の上書き（gcsfuse では全体ダウンロード + 再アップロードになる想定）
        $json = $this->payload($size, 2);
        $t = hrtime(true);
        $overwritten = file_put_contents($path, $json, LOCK_EX);
        $overwriteMs = $this->ms($t);
        unset($json);

        // 3 回目: tmp + rename
        $tmp = $path . '.' . bin2hex(random_bytes(4)) . '.tmp';
        $json = $this->payload($size, 3);
        $expectedHash = md5($json);
        $t = hrtime(true);
        $tmpWritten = file_put_contents($tmp, $json);
        $tmpWriteMs = $this->ms($t);
        unset($json);
        $t = hrtime(true);
        $renamed = @rename($tmp, $path);
        $renameMs = $this->ms($t);

        $t = hrtime(true);
        $read = file_get_contents($path);
        $readMs = $this->ms($t);
        $readHash = $read === false ? null : md5($read);
        unset($read);

        clearstatcache(true, $path);

        return [
            'ok' => $created === $size && $overwritten === $size && $tmpWritten === $size && $renamed && $readHash === $expectedHash,
            'size' => $size,
            'create_ms' => $createMs,
            'overwrite_ms' => $overwriteMs,
            'tmp_write_ms' => $tmpWriteMs,
            'rename_ms' => $renameMs,
            'read_ms' => $readMs,
            'filesize' => filesize($path),
            'content_matches' => $readHash === $expectedHash,
        ];
    }

    /**
     * 追加項目: chmod / is_writable / touch / glob / scandir / mkdir。
     *
     * @return array<string, mixed>
     */
    private function misc(): array
    {
        $path = $this->path('misc.json');
        file_put_contents($path, $this->payload(256, 1));

        $chmod = @chmod($path, 0600);
        $chmodError = $chmod ? null : (error_get_last()['message'] ?? 'unknown');
        clearstatcache(true, $path);
        $perms = fileperms($path);

        $touchTime = time() - 3600;
        $touch = @touch($path, $touchTime);
        clearstatcache(true, $path);
        $mtime = filemtime($path);

        $dir = $this->dir();
        $t = hrtime(true);
        $glob = glob($dir . '/*');
        $globMs = $this->ms($t);
        $t = hrtime(true);
        $scandir = scandir($dir);
        $scandirMs = $this->ms($t);
        // gcsfuse の readdir は . と .. を返さないので、固定で 2 を引かずに除外して数える
        $scandirCount = $scandir === false ? null : count(array_diff($scandir, ['.', '..']));

        $sub = $dir . '/subdir-' . bin2hex(random_bytes(2));
        $mkdir = @mkdir($sub, 0775);
        $isDir = is_dir($sub);
        $rmdir = $isDir && @rmdir($sub);

        return [
            'ok' => $glob !== false && $scandir !== false,
            'chmod' => $chmod,
            'chmod_error' => $chmodError,
            'perms_after_chmod' => $perms === false ? null : sprintf('%o', $perms & 0777),
            'is_writable' => is_writable($path),
            'is_writable_dir' => is_writable($dir),
            'touch' => $touch,
            'mtime_applied' => $mtime === $touchTime,
            'mtime' => $mtime,
            'glob_count' => $glob === false ? null : count($glob),
            'glob_ms' => $globMs,
            'scandir_count' => $scandirCount,
            'scandir_ms' => $scandirMs,
            'mkdir' => $mkdir,
            'mkdir_is_dir' => $isDir,
            'rmdir' => $rmdir,
        ];
    }

    /**
     * data.json 本体に size バイトの埋め草（pad キー）を入れる（0 なら外す）。#8 で POST /update をサイズ別に計測するために使う。
     * S3 には PUT しない（次の POST /update が PUT する）。
     *
     * @return array<string, mixed>
     */
    private function pad(int $size): array
    {
        $store = new JsonStore($this->config);
        $data = $store->read();
        if ($size > 0) {
            $data['pad'] = str_repeat('x', $size);
        } else {
            unset($data['pad']);
        }

        $t = hrtime(true);
        $store->write($data);
        $writeMs = $this->ms($t);
        unset($data);

        $path = $this->config->dataPath();
        clearstatcache(true, $path);

        return [
            'pad' => $size,
            'bytes' => filesize($path),
            'write_ms' => $writeMs,
        ];
    }

    /**
     * 検証用ディレクトリを削除する。
     *
     * @return array<string, mixed>
     */
    private function cleanup(): array
    {
        $dir = $this->config->dataDir . '/' . self::SUBDIR;
        if (!is_dir($dir)) {
            return ['removed' => 0, 'dir_removed' => false];
        }
        $removed = 0;
        foreach (glob($dir . '/*') ?: [] as $file) {
            if (is_file($file) && unlink($file)) {
                $removed++;
            } elseif (is_dir($file)) {
                @rmdir($file);
            }
        }
        $dirRemoved = @rmdir($dir);

        return ['removed' => $removed, 'dir_removed' => $dirRemoved];
    }

    /** 検証用ディレクトリのパス（無ければ作る） */
    private function dir(): string
    {
        $dir = rtrim($this->config->dataDir, '/') . '/' . self::SUBDIR;
        if (!is_dir($dir) && !@mkdir($dir, 0775, true) && !is_dir($dir)) {
            throw new RuntimeException(sprintf('検証用ディレクトリを作成できません: %s (%s)', $dir, error_get_last()['message'] ?? 'unknown'));
        }

        return $dir;
    }

    private function path(string $name): string
    {
        return $this->dir() . '/' . $name;
    }

    /**
     * 指定サイズちょうどの JSON 文字列。先頭の seq と末尾の seq_tail が一致するので、途中の内容を検出できる。
     */
    private function payload(int $size, int $seq): string
    {
        $head = sprintf('{"seq":%d,"pad":"', $seq);
        $tail = sprintf('","seq_tail":%d}' . "\n", $seq);
        $padLen = max(0, $size - strlen($head) - strlen($tail));

        return $head . str_repeat('x', $padLen) . $tail;
    }

    /**
     * @return array<string, mixed>|null
     */
    private function readJson(string $path): ?array
    {
        $raw = @file_get_contents($path);
        if ($raw === false) {
            return null;
        }
        $data = json_decode($raw, true);

        return is_array($data) ? $data : null;
    }

    /** 経過ミリ秒（小数 1 桁） */
    private function ms(int $startedNs): float
    {
        return round((hrtime(true) - $startedNs) / 1e6, 1);
    }

    /**
     * @param array<string, string> $params
     */
    private function intParam(array $params, string $name, int $default, int $min, int $max): int
    {
        $value = isset($params[$name]) && $params[$name] !== '' ? (int) $params[$name] : $default;
        if ($value < $min || $value > $max) {
            throw new InvalidArgumentException(sprintf('%s は %d〜%d の範囲で指定してください（指定値: %d）', $name, $min, $max, $value));
        }

        return $value;
    }

    /** /proc/mounts から DATA_DIR のマウント行（ファイルシステム種別とオプション）を探す */
    private function mountLine(string $dir): ?string
    {
        $mounts = @file('/proc/mounts', FILE_IGNORE_NEW_LINES) ?: [];
        $best = null;
        foreach ($mounts as $line) {
            $parts = explode(' ', $line);
            $target = $parts[1] ?? '';
            if ($target !== '' && str_starts_with(rtrim($dir, '/') . '/', rtrim($target, '/') . '/') && ($best === null || strlen($target) > strlen(explode(' ', $best)[1]))) {
                $best = $line;
            }
        }

        return $best;
    }
}
