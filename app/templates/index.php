<?php
/**
 * トップページのテンプレート。
 *
 * @var array<string, mixed> $data   JSON マスタの現在値
 * @var \App\Config          $config
 * @var string|null          $result 直前の更新結果メッセージ
 * @var string|null          $error  直前のエラーメッセージ
 */

declare(strict_types=1);

$h = static fn (mixed $v): string => htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');
?>
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>EC2 to Cloud Run PoC</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem auto; max-width: 48rem; padding: 0 1rem; color: #222; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 1.5rem; }
    th, td { border: 1px solid #ccc; padding: .4rem .6rem; text-align: left; vertical-align: top; }
    th { background: #f3f3f3; width: 30%; }
    pre { margin: 0; white-space: pre-wrap; word-break: break-all; }
    form { display: grid; gap: .5rem; grid-template-columns: 8rem 1fr; align-items: center; margin-bottom: 1.5rem; }
    form button { grid-column: 2; justify-self: start; padding: .4rem 1rem; }
    .msg { padding: .6rem .8rem; border-radius: 4px; margin-bottom: 1rem; }
    .ok { background: #e6f4ea; border: 1px solid #b7e1c1; }
    .ng { background: #fdecea; border: 1px solid #f5c2c0; }
    footer { color: #666; font-size: .85rem; }
    footer code { background: #f3f3f3; padding: 0 .2rem; }
  </style>
</head>
<body>
  <h1>JSON 更新 → S3 アップロード</h1>

  <?php if ($result !== null): ?>
    <div class="msg ok"><?= $h($result) ?></div>
  <?php endif; ?>
  <?php if ($error !== null): ?>
    <div class="msg ng"><?= $h($error) ?></div>
  <?php endif; ?>

  <h2>現在の JSON（<?= $h($config->dataPath()) ?>）</h2>
  <table>
    <tbody>
    <?php foreach ($data as $k => $v): ?>
      <tr>
        <th><?= $h($k) ?></th>
        <td><pre><?= $h(is_scalar($v) || $v === null ? (string) $v : json_encode($v, JSON_UNESCAPED_UNICODE)) ?></pre></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>

  <h2>更新</h2>
  <form method="post" action="/update">
    <label for="key">key</label>
    <input id="key" name="key" required pattern="[A-Za-z0-9_.\-]{1,64}" placeholder="例: message">
    <label for="value">value</label>
    <input id="value" name="value" placeholder="例: hello">
    <button type="submit">更新して S3 へアップロード</button>
  </form>

  <footer>
    WRITE_MODE=<code><?= $h($config->writeMode) ?></code>
    / DATA_DIR=<code><?= $h($config->dataDir) ?></code>
    / S3=<code>s3://<?= $h($config->s3Bucket) ?>/<?= $h($config->s3Key()) ?></code>
    <?php if ($config->s3Endpoint !== null): ?>
      / endpoint=<code><?= $h($config->s3Endpoint) ?></code>
    <?php endif; ?>
    <?php if ($config->usesWebIdentity()): ?>
      / 認証=<code>WIF <?= $h($config->awsRoleArn) ?></code>
    <?php else: ?>
      / 認証=<code>SDK 既定チェーン</code>
    <?php endif; ?>
    / PHP <?= $h(PHP_VERSION) ?>
  </footer>
</body>
</html>
