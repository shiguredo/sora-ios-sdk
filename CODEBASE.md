# CODEBASE

## Swift 6 consumer package

外部の iOS アプリと同じ形 (通常の SwiftPM package 依存) で `import Sora` する consumer package を
`TestConsumers/Swift6Consumer/` に置いている。検証の内容と scenario の追加手順は consumer package の
`README.md` にある。ここにはリポジトリ側の運用 (Makefile の target と公開 API baseline の
更新手順) を書く。

### Makefile の target

| target | 内容 |
| --- | --- |
| `make consumer-build SCHEME=<Target>` | consumer package の 1 scheme を Release で build する (`SCHEME` の既定値は `ConsumerCore`) |
| `make consumer-check-negative` | compile 失敗を期待する file を 1 file ずつ typecheck する |
| `make api-baseline` | 公開 API baseline を生成し、commit 対象の file を上書きする |
| `make api-check` | commit 済み baseline と build 済み module を比較する |
| `make api-check-fresh` | commit 済み baseline が現在の `Sora` module と一致していることを検証する (追加も検出する) |

- `XCODE` と `XCODE_SDK` は `XCODE=/Applications/Xcode_26.6.app XCODE_SDK=iphoneos26.5` のように
  上書きする。CI は `.github/workflows/consumer-test.yml` の `swift6-consumer` job が matrix の値で呼び、
  同じ job で `make fmt-lint` と `make lint` も実行する
- `make consumer-build` は `-derivedDataPath build/consumer` に build する。`PRODUCTS` などの
  path は `DERIVED_DATA` の絶対 path から導出しているため、`DERIVED_DATA` を相対 path で
  上書きしても動く
- `make api-baseline` は `API_XCODE` と `API_SDK_VERSION` が実行環境と一致しない場合に失敗する。
  `make api-check` は baseline の生成情報 (`*.info.txt`) と実行環境が一致しない場合に失敗する。
  これは、SDK が違う module との比較で差分が SDK の差に汚れるのを防ぐためである

### 公開 API baseline

baseline は `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と、その生成情報
`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.info.txt` の 2 file で、`swift-api-digester`
の dump を commit している。

生成する:

```
make consumer-build SCHEME=ConsumerCore
make api-baseline
```

- Xcode 26.6 と `iphoneos26.5` が必要。別の Xcode と SDK では意図的に失敗する。 此のバージョンは E2E CI ランナー Mac マシンのものと合わせる
- dump には `-avoid-location` と `-avoid-tool-args` を付け、絶対 path と実行情報を入れない
- dump した JSON が `ABIRoot.name == "Sora"` であること、`ABIRoot` の `children` が 100 件以上
  であること、大きさが 1 MiB 以上であることを検証してから commit 対象の file を上書きする。
  この検証が無いと、module を読み込めずに書かれた `NO_MODULE` の JSON を baseline として
  commit してしまい、比較が無言で無効になる
- baseline の JSON は 1.7 MB 程度あり末尾改行で終わらないため、`prek.toml` で
  `check-added-large-files` と `end-of-file-fixer` の除外 (JSON のみ) と `check-json` の対象を
  設定している。baseline の file 名を変えるときは除外の pattern も更新する

比較する:

```
make api-check
```

- CI の `swift6-consumer` job が `make api-check-fresh` を呼ぶ (`api-check-fresh` は `api-check` を
  実行してから fresh な dump と比較する)。`api-baseline` は CI から呼ばない (commit 済み baseline を
  上書きして自分自身と比較することになるため)
- `-input-paths` は使わない。`-diagnose-sdk` は `-I` / `-F` で読み込む module を「今回」側、
  `-baseline-path` の JSON を基準として比較する
- `api-check` が検出できるのは公開 API の削除・変更と準拠の削除。**API の追加は `api-check` では
  検出できない**。`api-check-fresh` が commit 済み baseline と fresh な dump の一致を検証するため、
  追加と再生成漏れはこちらで検出する (API を追加する変更では、同じ変更で baseline を再生成する)
- breakage は warning として報告され、終了コードは 0 になり得る。そのため終了コードではなく
  digester の出力で判定し、出力が空でなければ (breakage でも toolchain の出力でも) 失敗させる

### baseline を更新する手順

1. 公開 API を変更する変更に、同じ commit で baseline の再生成を含める。新しい API を使う
   scenario を consumer package に追加する場合も同じ
2. `git diff --stat TestConsumers/Swift6Consumer/ApiBaseline/` で差分の大きさを確認する
3. `git diff TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を読み、
   deprecation annotation の追加・変更**以外**の差分を必ずレビューする。特に型の変更、
   準拠の削除、`printedName` や `declKind` の変化、意図しない symbol の消滅を確認する
4. 差分が SDK の差によるものに見える場合は、`iphoneos26.5.info.txt` の `xcodebuild` と `sdk` が
   実行環境と一致しているかを確認する。一致していない baseline は commit しない
5. `make api-check-fresh` が成功することを確認する

`children` は source の宣言順を保つため、公開 API を変えずに public 宣言や enum case を
並べ替えた場合も baseline の再生成が必要になる (差分は並べ替えとして現れる)。

### Xcode を更新するとき

1. `README.md` のシステム条件、`skills/sora-ios-sdk/SKILL.md` の動作条件、
   `TestConsumers/Swift6Consumer/README.md` の Xcode と SDK の記述、
   `.github/workflows/build.yml` の `env.XCODE` / `env.XCODE_SDK`、
   `.github/workflows/deploy-apidoc.yml` の `env.XCODE`、`.github/workflows/e2e-test.yml` の
   `env.XCODE_SDK` を更新する (`e2e-test.yml` の未使用の `XCODE` は更新しない)
2. `.github/workflows/consumer-test.yml` の `swift6-consumer` の matrix を更新する
3. `Makefile` の `XCODE_SDK` と `API_XCODE` を更新する (baseline の file 名と `API_SDK_VERSION` は
   `XCODE_SDK` から導出され、`build` target の SDK も `XCODE_SDK` に追随する)
4. `XCODE_SDK` / `API_XCODE` を変えた場合、または `*.info.txt` の `xcodebuild` と `sdk` が
   実行環境と一致しない場合は `make api-baseline` で baseline と生成情報を作り直す。
   `XCODE_SDK` / `API_XCODE` が同じで `*.info.txt` の `xcodebuild` と `sdk` が実行環境と
   一致する場合だけ再生成しない。再生成の有無にかかわらず `make api-check-fresh` が
   成功することを確認する
5. 差分をレビューする。SDK の更新に伴う差分 (deprecation の追加など) と、Sora 側の変更に
   よる差分を分けて確認する
6. SDK の版が変わる場合は baseline の file 名も新しい版に変える。古い baseline は残さない
