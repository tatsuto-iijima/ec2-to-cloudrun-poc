<?php

declare(strict_types=1);

namespace App;

use JsonException;
use RuntimeException;

/**
 * JSON マスタファイルの読み書き。
 *
 * 現行アプリと同じく、ローカルファイルシステム（Cloud Run では gcsfuse のマウント先）上の
 * 1 ファイルを読み → 更新 → 書き戻す。書き込み方式は Config::$writeMode で切り替える。
 */
final class JsonStore
{
    public function __construct(private readonly Config $config)
    {
    }

    /**
     * JSON を読み込んで連想配列で返す。ファイルが無ければ初期データを返す（この時点では書き込まない）。
     *
     * @return array<string, mixed>
     */
    public function read(): array
    {
        $path = $this->config->dataPath();
        if (!file_exists($path)) {
            return self::initialData();
        }

        $raw = file_get_contents($path);
        if ($raw === false) {
            throw new RuntimeException(sprintf('JSON の読み込みに失敗しました: %s', $path));
        }

        try {
            $data = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            throw new RuntimeException(sprintf('JSON の解析に失敗しました: %s (%s)', $path, $e->getMessage()), 0, $e);
        }

        return is_array($data) ? $data : [];
    }

    /**
     * 連想配列を JSON として書き込む。
     *
     * @param array<string, mixed> $data
     */
    public function write(array $data): void
    {
        $path = $this->config->dataPath();
        $dir = dirname($path);
        if (!is_dir($dir) && !mkdir($dir, 0775, true) && !is_dir($dir)) {
            throw new RuntimeException(sprintf('DATA_DIR を作成できません: %s', $dir));
        }

        $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n";

        match ($this->config->writeMode) {
            Config::WRITE_MODE_LOCK => $this->writeWithLock($path, $json),
            Config::WRITE_MODE_RENAME => $this->writeWithRename($path, $json),
        };
    }

    /**
     * 現行アプリと同じ方式: file_put_contents + LOCK_EX で既存ファイルを上書きする。
     * gcsfuse ではロックがカーネル内ローカルに処理される見込み（docs/01 参照）。戻り値を必ず確認する。
     */
    private function writeWithLock(string $path, string $json): void
    {
        $written = file_put_contents($path, $json, LOCK_EX);
        if ($written === false) {
            throw new RuntimeException(sprintf(
                'JSON の書き込み（LOCK_EX）に失敗しました: %s (%s)',
                $path,
                error_get_last()['message'] ?? 'unknown'
            ));
        }
    }

    /**
     * 一時ファイルに書いてから rename で差し替える方式。
     * 一時ファイルは同じディレクトリに置く（gcsfuse でディレクトリをまたぐ rename を避けるため）。
     */
    private function writeWithRename(string $path, string $json): void
    {
        $tmp = sprintf('%s.%s.tmp', $path, bin2hex(random_bytes(4)));

        if (file_put_contents($tmp, $json) === false) {
            throw new RuntimeException(sprintf(
                '一時ファイルの書き込みに失敗しました: %s (%s)',
                $tmp,
                error_get_last()['message'] ?? 'unknown'
            ));
        }

        if (!rename($tmp, $path)) {
            $message = error_get_last()['message'] ?? 'unknown';
            @unlink($tmp);
            throw new RuntimeException(sprintf('rename に失敗しました: %s -> %s (%s)', $tmp, $path, $message));
        }
    }

    /**
     * ファイルが無いときの初期データ。
     *
     * @return array<string, mixed>
     */
    private static function initialData(): array
    {
        return [
            'message' => 'EC2 to Cloud Run PoC',
            'counter' => 0,
        ];
    }
}
