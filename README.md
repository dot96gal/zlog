# zlog

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zlog/)
[![CI](https://github.com/dot96gal/zlog/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zlog/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zlog/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zlog/actions/workflows/release.yml)

Zig のシンプルな構造化ロギングのライブラリ。

- タイムスタンプ（RFC 3339）付きログ出力
- ログレベルフィルタリング（`err` / `warn` / `info` / `debug`）
- テキスト形式・JSON 形式の切り替え
- ロガー名（スコープ）によるログの区別
- `with*` メソッドによる不変な設定変更

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

## 要件

- Zig 0.16.0 以上

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zlog を追加する。

最新のタグは [GitHub Releases](https://github.com/dot96gal/zlog/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zlog/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zlog = .{
        .url = "https://github.com/dot96gal/zlog/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zlog モジュールをインポートする。

```zig
const zlog_dep = b.dependency("zlog", .{
    .target = target,
    .optimize = optimize,
});
const zlog_mod = zlog_dep.module("zlog");
exe.root_module.addImport("zlog", zlog_mod);
```

### 使い方

#### Logger の初期化

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const writer = &file_writer.interface;

    const logger = zlog.Logger.init(io, writer, .info);
}
```

#### ログ出力

`attrs` にはコンパイル時固定のフィールド名と実行時の値を持つ匿名構造体を渡す。

```zig
try logger.err("connection failed", .{ .host = "db.example.com" });
try logger.warn("disk usage high", .{ .percent = 85 });
try logger.info("server started", .{ .port = 8080 });
try logger.debug("request received", .{ .method = "GET", .path = "/api/v1/users" });
```

出力例（テキスト形式）：

```
2026-04-20T12:34:56Z [ERROR] connection failed host="db.example.com"
2026-04-20T12:34:56Z [WARN] disk usage high percent=85
2026-04-20T12:34:56Z [INFO] server started port=8080
2026-04-20T12:34:56Z [DEBUG] request received method="GET" path="/api/v1/users"
```

#### JSON 形式

```zig
const json_logger = logger.withFormat(.json);
try json_logger.info("user logged in", .{ .user_id = 42, .ip = "127.0.0.1" });
```

出力例：

```
{"time":"2026-04-20T12:34:56Z","level":"info","msg":"user logged in","user_id":42,"ip":"127.0.0.1"}
```

#### ロガー名（スコープ）

```zig
const db_logger = logger.withLoggerName("database");
try db_logger.info("query executed", .{ .duration_ms = 42 });
```

出力例：

```
2026-04-20T12:34:56Z [INFO] [database] query executed duration_ms=42
```

#### ログレベルフィルタリング

`Logger.init` の第 3 引数で最小出力レベルを指定する。指定レベルより詳細なログは出力されない。

```zig
// .info レベル以上のみ出力（.debug は出力されない）
const logger = zlog.Logger.init(io, writer, .info);
```

#### `with*` メソッドによる設定変更

各 `with*` メソッドは設定を変更した**新しい Logger** を返す。元の Logger は変更されない。

```zig
const logger = zlog.Logger.init(io, writer, .info);
const debug_logger = logger.withLevel(.debug);       // ログレベル変更
const json_logger  = logger.withFormat(.json);        // フォーマット変更
const db_logger    = logger.withLoggerName("db");     // ロガー名付与
const other_logger = logger.withWriter(other_writer); // 出力先変更
```

### API リファレンス

#### `Error`

| 値 | 説明 |
|----|------|
| `WriteFailed` | 出力先への書き込みに失敗した |

#### `Format`

| 値 | 説明 |
|----|------|
| `.text` | テキスト形式のログ（デフォルト） |
| `.json` | JSON オブジェクト形式のログ |

#### `Logger`

| 関数 | シグネチャ | 説明 |
|------|-----------|------|
| `init` | `(io, writer, level) Logger` | Logger を生成する |
| `withWriter` | `(writer) Logger` | 出力先を変更した新しい Logger を返す |
| `withLevel` | `(level) Logger` | ログレベルを変更した新しい Logger を返す |
| `withFormat` | `(format) Logger` | フォーマットを変更した新しい Logger を返す |
| `withLoggerName` | `(name) Logger` | ロガー名を設定した新しい Logger を返す |
| `withTimestamp` | `(ts) Logger` | 固定タイムスタンプを設定した新しい Logger を返す（テスト用） |
| `err` | `(msg, attrs) Error!void` | エラーレベルでログを出力する |
| `warn` | `(msg, attrs) Error!void` | 警告レベルでログを出力する |
| `info` | `(msg, attrs) Error!void` | 情報レベルでログを出力する |
| `debug` | `(msg, attrs) Error!void` | デバッグレベルでログを出力する |

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zlog
cd zlog
mise install
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | リント |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run example:basic` | basic サンプルの実行 |
| `mise run build-docs` | API ドキュメントのビルド |
| `mise run serve-docs` | API ドキュメントのローカルサーブ |
| `mise run release <version>` | バージョンバンプ・コミット・タグ・プッシュ |

### ファイル構成

```
zlog/
├── src/
│   ├── root.zig      # 公開 API のエクスポート
│   └── logger.zig    # Logger 実装・テスト
├── examples/
│   └── basic.zig     # 使用例
├── build.zig         # ビルドスクリプト
└── build.zig.zon     # 依存関係・パッケージ定義
```

### 設計方針

**構造化ログの attrs に `comptime anytype` を採用**

フィールド名はコンパイル時固定、値は実行時でも渡せる。アロケータ不要でシンプルに保てる。

```zig
logger.info("user logged in", .{ .user_id = user_id, .ip = ip_str });
```

**`with*` メソッドによる不変設定**

各 `with*` は新しい Logger を返し、元の Logger を変更しない。スコープ付きロガーを派生させやすい。

**フォーマットは enum で切り替え**

テキスト / JSON の 2 択を `switch` で分岐するシンプルな実装。

### テスト

テストは `src/logger.zig` 内に実装ごとに記述している。

```sh
mise run test
```

---

## ライセンス

[MIT](LICENSE)
