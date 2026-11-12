# libwebrtc m156 更新後の残りの実機確認を行う

- Created: 2026-11-12
- Completed: {YYYY-MM-DD}
- Branch: feature/update-libwebrtc-m156-verification
- Polished: {YYYY-MM-DD}

## 目的

libwebrtc を m156.8078.5.1 に更新する 0194 は 2026.5.0 でリリース済みで、2026.5.1 が現行である。ただし、m156 の変更で影響し得る次の項目が実機で未確認のまま残っている。これらを確認し、結果を記録する。

- re-offer で受信コーデックが変わったときのデコード継続とキーフレーム要求
- 音声品質 (AEC / AGC / 遅延)
- Simulcast の帯域制限時の挙動

## 現状

0194 では次を確認済みである。

- `Package.swift`、`Sora/PackageInfo.swift`、`README.md`、`skills/sora-ios-sdk/SKILL.md`、`CHANGES.md`、`THIRD_PARTY_LICENSES.md` の更新
- CI の Build / E2E / Consumer Test の成功
- 録音インジケーター (プライバシーインジケーター) の消灯 / 点灯
- VP8 / VP9 / AV1 / H.264 / H.265 の 5 コーデックの送受信
- ステレオ出力の聴感 (iOS 実機 / ヘッドホン)
- スポットライト切り替え時の `re-offer` / `re-answer`、映像継続、キーフレーム要求なし、ICE の connected 維持

次の項目は未確認である。

- re-offer で受信コーデックが変わった場合のデコード継続とキーフレーム要求
- 音声品質 (AEC / AGC / 遅延)
- Simulcast の帯域制限時の挙動

ステレオ入力は 0009 が pending のため対象外とする。

## 確認方法

### 1. re-offer で受信コーデックが変わる場合

- 送信側を 2 つ用意し、片方を VP8、もう片方を VP9 にする
- 受信側の `Configuration.videoCodec` は `.default` にして、両方を受け入れられるようにする
- 受信側をスポットライトで接続し、VP9 の送信者から VP8 の送信者へフォーカスを切り替える
- `MediaChannelHandlers.onReceiveSignalingJSON` で `re-offer` を確認し、SDP の video コーデックが変わることを確認する
- `getStats` の `inbound-rtp` 映像で、切り替え前後も `framesDecoded` が増え続け、`pliCount` が急増せず、`freezeCount` / `totalFreezesDuration` が増えないことを確認する
- 受信する `mid` が切り替わるため、統計は `mid` ごとに確認する

### 2. 音声品質 (AEC / AGC / 遅延)

- `audioStereoOutputEnabled = false`、`bypassVoiceProcessing = false` の既定の Voice Processing 経路で確認する
- 送信側はスピーカー出力にする (`Sora.setAudioMode(.voiceChat(output: .speaker))` など)
- AEC: スピーカーから相手の音を出し、同じ端末のマイクで拾わせる。相手側に自分の声が遅れて返ってこないこと、エコーやハウリングが起きないことを確認する
- AGC: 小さい声、普通の声、大きい声で話し、受信側の音量が極端に変わらず、大きい声で割れないことを確認する。必要なら `getStats` の `audioLevel` と `totalAudioEnergy` を記録する
- 遅延: 会話して不自然な間合いにならないことを確認する。`getStats` の `jitterBufferDelay` / `jitterBufferEmittedCount` と `roundTripTime` を記録する。ループバックで測る場合は往復時間を 2 で割る
- 出力経路 (内蔵スピーカー / 受話口 / Bluetooth HFP / A2DP) を記録する

### 3. Simulcast の帯域制限時の挙動

- `Configuration.simulcastEnabled = true`、`role = .sendrecv`、映像有効で接続する
- answer に 3 層の rid が含まれ、`degradationPreference` / `networkPriority` が `sender.parameters` に残ることを確認する
- `SoraTests/SimulcastE2ETests.swift` のテストが成功することを確認する
- Network Link Conditioner や Sora 側の帯域制限で帯域を絞り、レイヤーが落ちても切断せず、映像が継続することを確認する
- `getStats` の `qualityLimitationReason` / `qualityLimitationDurations` を記録する

## 完了条件

- 上の 3 項目を実機で確認し、結果と検証環境を「解決方法」に記録していること
- コーデック変更では、re-offer の SDP で受信コーデックが変わり、映像が継続し、`pliCount` が急増しないことを確認していること
- 音声品質では、AEC / AGC / 遅延に問題がないことを確認していること
- Simulcast では、帯域制限でレイヤーが落ちても切断せず、映像が継続することを確認していること
- 確認できなかった項目がある場合は、その理由と代替の確認方法を記録していること
- 確認の結果コード変更が必要になった場合は、別 issue を作成していること

## 解決方法

実機確認の結果をここに記録する。
