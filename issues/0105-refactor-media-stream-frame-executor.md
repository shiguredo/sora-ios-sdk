# MediaStream の映像フレーム処理 executor を単一化する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-media-stream-frame-executor
- Polished: 2026-09-02

## 目的

`MediaStream` へ入力される映像 frame、`VideoFilter` の実行、WebRTC video source への送信を stream 単位の ordered executor へ集約する。

カメラ、ReplayKit、利用者の直接送信が並行しても filter と renderer の順序が崩れず、停止後の古い frame が新しい stream state へ適用されない構造にする。

## 現状

`Sora/MediaStream.swift` の `BasicMediaStream.send(videoFrame:)` は、呼び出し元の executor 上で `videoFilter` を読み、filter を実行し、`RTCVideoSource.capturer(_:didCapture:)` を呼ぶ。

このメソッドには次の入力元がある。

- `CameraVideoCapturerDelegate` の capture callback
- `ScreenCaptureController` の送信 queue
- 利用者による `MediaStream.send(videoFrame:)` の直接呼び出し

`videoFilter` property の取得・変更には同期がなく、`VideoFilter` に Sendable または executor 契約もない。同じ filter instance が複数の入力元から同時に実行される可能性がある。

`videoRenderer` の追加・除去、`videoEnabled` / `audioEnabled` の変更、`terminate()` からの renderer callback も呼び出し元の executor に依存する。

`VideoFrame` は raw `RTCVideoFrame` または pixel buffer を保持するため、単純に `Task` や `DispatchQueue` へ渡すだけでは frame lifetime と Sendable を保証できない。

open の `0057` は新しい Media Processors API の追加を目的としている。本 issue は、既存 `VideoFilter` と frame 送信経路が安全に動作する executor 基盤だけを対象とし、processor 機能を追加しない。

## 設計方針

### stream frame owner

- `BasicMediaStream` ごとに frame-processing 用の serial executor または actor を持つ。
- frame event に stream identity、transport epoch、sequence、owned frame / adapter handle を含める。
- camera、screen capture、public send のすべてを 1 本の ordered ingress へ接続する。
- disconnect、redirect / 再ネゴシエーション、stream terminate 後は、古い epoch の frame を破棄する。

### VideoFilter

- legacy `VideoFilter` は frame executor 上だけで直列に呼ぶ。
- filter property の交換も同じ executor 上で順序付ける。
- 既存 `VideoFilter` に直接 `Sendable` を要求せず、既存 conformer を壊さない。順序と安全性は executor 上の直列化で保証する。
- 新しい Sendable processor 契約を追加する場合は `0057` で扱い、本 issue の executor を基盤として利用する。

### frame ownership

- ingress へ渡す前に、WebRTC / CoreVideo の thread affinity と lifetime を満たす owned frame または内部 handle へ変換する。
- raw frame を広域の `@unchecked Sendable` wrapper に入れない。
- WebRTC video source の呼び出しが必要な vendor executor を確認し、frame executor から adapter 経由で配送する。

### renderer との接続

- filter 後の frame と renderer event に同じ sequence を利用できる構造にする。
- MainActor renderer への最終配送は `0027`、custom queue の公開指定は `0060` で扱う。
- add、frame、remove、disconnect に加えて、`videoEnabled` / `audioEnabled` の変更に伴う switch と `onChange(size:)` を含む renderer event の因果順序を、個別の unstructured Task 生成に依存させない。

## スコープ外

- 新しい Media Processors 機能は `0057` で扱う。
- MainActor renderer API は `0027` で扱う。
- renderer の custom queue 公開 API は `0060` で扱う。
- raw WebRTC 型の公開 API からの撤去は `0070` と整合させる。
- audio sink の executor 再設計は本 issue に含めない。

## テスト方針

モックやスタブは使用しない。

- 実カメラ、実 ReplayKit、public `send(videoFrame:)` から同じ実 `MediaStream` へ frame を入力する。
- 実際の `VideoFilter` 実装を使い、同時実行されず sequence 順に呼ばれることを確認する。
- filter の交換と frame 入力を競合させ、交換前後の境界が決定的であることを確認する。
- disconnect、redirect / 再ネゴシエーション、terminate 後に古い epoch の frame が送られないことを確認する。
- 現行 `VideoFilter.filter(_:)` は非 optional を返し drop 経路を持たないため、frame の drop は `0057` の新 processor 契約で扱う。本 issue では filter の連続・並行入力でも後続 frame が停止・追い越しなく sequence 順に処理されることを確認する。
- Thread Sanitizer を補助的に有効化し、長時間の frame 入力で queue が無制限に増えないことを確認する。
- テストには、入力元ごとの event sequence と期待する破棄条件を日本語コメントで明記する。

## 完了条件

- stream ごとに映像 frame 処理の所有 executor が 1 つ存在すること。
- camera、screen capture、public send が同じ ordered ingress を経由すること。
- legacy `VideoFilter` の実行と交換が同じ executor 上で順序付けられること。
- stale transport epoch の frame が WebRTC video source と renderer へ配送されないこと。
- raw frame を広域の unchecked wrapper で executor 越境させていないこと。
- add、frame、remove、disconnect に加えて、switch、size を含む renderer event の因果順序が明示的に保証されること。
- `0057`、`0027`、`0060` が利用できる基盤と責務境界が文書化されていること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
