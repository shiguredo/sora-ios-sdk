# E2E の testSendonlyDummyAudio がホストの音声サブシステムの状態に依存して失敗する問題を修正する

- Created: 2026-09-29
- Completed:
- Priority: High
- Branch: feature/fix-e2e-audio-host-dependency
- Polished:

## 目的

CI の E2E が、self-hosted ランナーのホスト macOS の音声サブシステムの状態によって失敗しなくなるようにする。

`SoraTests/SendonlyE2ETests.swift` の `testSendonlyDummyAudio` は、接続の同期パスで `DummyAudioDevice.initialize(with:)` から `AVAudioSession.setActive(true)` を実行する唯一の E2E テストである。ホストの音声サブシステムがこの呼び出しに応答しない状態になると、テストは接続できないまま `Configuration.connectionTimeout` で失敗する。実際に self-hosted ランナーの `macos-m1-2` で 2026-09-28 以降この失敗が連続して再現し、同じ commit が `macos-m1` では成功していた。ランナーの状態に CI の成否が左右される状態を解消する。

## 現状

### 事象

- 失敗するテスト: `SoraTests/SendonlyE2ETests.swift` の `testSendonlyDummyAudio`
- 失敗するランナー: `macos-m1-2` (self-hosted / macOS ARM64 / Apple-M1)
- エラー: `接続に失敗した: connectionTimeout`
- 失敗までの時間: 約 60 秒 (`Configuration.connectionTimeout` の 60 秒で `ConnectionTimer` が発火する)
- 同一 run の他のテスト (映像系、既定 ADM を使う recvonly、unit) はすべて成功する
- 実行例 (失敗): https://github.com/shiguredo/sora-ios-sdk/actions/runs/36519591808/job/109249323951
- 実行例 (失敗・coreaudiod 再起動後): https://github.com/shiguredo/sora-ios-sdk/actions/runs/36522872612/job/109259391564

### 再現手順

1. `macos-m1-2` で E2E ワークフローを実行する
2. `SendonlyE2ETests` の `testSendonlyDummyAudio` が接続を開始し、`DummyAudioDevice.initialize(with:)` が `AVAudioSession.setActive(true)` を呼ぶ
3. `setActive` が戻らないまま 60 秒が経過し、`接続に失敗した: connectionTimeout` で失敗する

`macos-m1-2` では 10 回以上連続で再現し、同じ commit を `macos-m1` で実行すると成功する。

### 原因

`Sora/DummyAudioDevice.swift` の `DummyAudioDevice.initialize(with:)` は、`playoutHandler` を渡さない場合に `setCategory(.playAndRecord)` と `setActive(true)` を実行する。`macos-m1-2` のホストでは、既定入力 (USB 接続のカメラ、16000 Hz) と既定出力 (内蔵スピーカー、48000 Hz) をまとめる集約デバイスの構築で coreaudiod への同期 IPC が戻らず、`setActive` がブロックしたまま接続がタイムアウトする。

`sample` で採取したスタック (抜粋。上ほど呼び出し元):

```
DispatchQueue: DefaultDeviceAggregate (serial)
  DummyAudioDevice.initialize(with:)
    AVAudioSession privateSetActive:withOptions:error:core:
      ATDefaultDeviceAggregate primarySessionIsActivatingWithInputCategory:
        DefaultDeviceAggregate::buildDefaultAggregate
          CAListenerProxy::DeviceAggregateListener::callout
            AQMEIO_HAL::HandleDefaultDeviceChange / AQMEIO_HAL::SelectDevice
              AudioDeviceCreateIOProcID
                HALC_ShellDevice::CreateIOProcID
                  HALC_ProxyIOContext::_TellServerAboutStreamUsage
                    HALC_ProxyObject::SetPropertyData
                      mach_msg (coreaudiod の応答待ちのまま戻らない)
```

60 秒のタイムアウト後も 100 秒以上戻らないことを hang sample で確認している。`coreaudiod`、`AudioComponentRegistrar`、Simulator の音声 IO サービスを再起動しても同じ経路で再現したため、ホストのカーネル側の音声ドライバの状態が残っていると見られる。

### リポジトリ側の問題

原因はホスト側の環境要因だが、`testSendonlyDummyAudio` が接続の同期パスでホストの音声ハードウェア経路に依存しているため、CI の成否が特定のランナーの状態に左右される。なお、既定 ADM を使う recvonly の E2E は入力側を要求しないため同じランナーでも成功しており、入力と出力を集約する経路だけが影響を受けている。

調査用ブランチ `feature/debug-e2e-audio-timeout-investigation` で `playoutHandler` を渡す経路へ変更したところ、失敗していた `macos-m1-2` で E2E が成功した (https://github.com/shiguredo/sora-ios-sdk/actions/runs/36528905119)。本 issue ではこの変更を、実装とテストとして整えたうえで取り込む。

## 設計方針

- `testSendonlyDummyAudio` は `DummyAudioDevice` に `playoutHandler` を渡す経路で実行し、共有 AudioSession と音声ハードウェアに触れないようにする。`playoutHandler` は既存のパラメータであり、「指定時は AudioSession と音声ハードウェアを使わない」契約が `Sora/DummyAudioDevice.swift` の doc コメントに既にある
- 録音側の経路 (timer による PCM 生成から ADM への注入) と assert (OPUS 統計、bytesSent / packetsSent、接続状態、切断後の終端状態) は変えない。このテストの目的はダミー音声を送信できることの確認であり、AudioSession の有効化は検証対象ではない (`setActive` が失敗しても警告ログのみで処理は継続し、成否は assert されていない)
- `playoutHandler` を渡さない経路 (AudioSession の有効化) の確認は、実機でだけ実行するテストとして残す。Simulator の AudioSession は実機の代替にならず、実行すると再びホストの状態に依存するため、`#if targetEnvironment(simulator)` で skip する。`0119` が `AUAudioUnit` (RemoteIO) を Simulator の CI のスコープ外としている整理と揃える
- SDK の production コードは変更しない
- ホスト側のハングはランナーの運用で解消する (再起動で復旧しない場合は既定の入力 / 出力デバイスの構成を切り分ける)。リポジトリ側では扱わない

## 完了条件

- `testSendonlyDummyAudio` が共有 AudioSession と音声ハードウェアに触れず、ホストの音声サブシステムの状態に依存しないこと
- ダミー音声送信の検証内容 (OPUS 統計、bytesSent / packetsSent、接続 / 切断、終端状態) が変わっていないこと
- AudioSession を有効化する経路が実機で確認できる形で残っていること
- 失敗していた `macos-m1-2` で CI の E2E が成功すること

## 解決方法

(実装時に記載する)
