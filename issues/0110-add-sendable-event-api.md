# executor 契約を持つ Sendable event API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-event-api
- Polished:

## 目的

接続、シグナリング、DataChannel、stream のイベントを Swift 6 の actor / Task から安全に購読できる、executor 契約付きの Sendable event API を追加する。

既存の mutable handler bag と callback API を維持しながら、新しい API では payload lifetime、配送順序、reentrancy、配送 executor を明示する。

## 現状

次の公開 handler 型は、mutable な optional closure property を保持する class として実装されている。

- `Sora/Sora.swift` の `SoraHandlers`
- `Sora/MediaChannel.swift` の `MediaChannelHandlers`
- `Sora/WebSocketChannel.swift` の `WebSocketChannelHandlers`
- `Sora/MediaStream.swift` の `MediaStreamHandlers`
- `Sora/CameraVideoCapturer.swift` の `CameraVideoCapturerHandlers`

closure に `@Sendable` 制約はなく、handler の設定変更と callback 実行を同期する共通方針もない。

executor の説明は一部の DataChannel callback にだけあり、同じ handler bag 内でも次が統一されていない。

- callback が呼ばれる executor
- callback 間の順序
- callback 中に同期 API を再入できるか
- payload が callback 終了後も利用可能か
- 接続開始後に handler を変更した場合の反映時点

payload には `MediaChannel`、`MediaStream`、`RTCAudioSession`、Signaling object などの mutable reference と raw WebRTC 型が含まれる。既存 closure に直接 `@Sendable` を追加すると、利用者の non-Sendable capture が compile error になる。

## 前提となる issue

- `0100`: 接続イベントの ordered ingress と state snapshot
- `0101`: signaling event の ordered ingress
- `0102`: mutable handler bag と設定 snapshot の分離
- `0105`: stream frame event の順序保証
- `0107`: 外部 consumer fixture

## 設計方針

### event model

- core event を表す public の Sendable enum / struct を追加する。
- payload は connection ID、stream ID、label、immutable state snapshot、`Data`、Sendable error snapshot などに限定する。
- `MediaChannel`、`MediaStream`、raw WebRTC object を event payload として直接渡さない。
- event に論理接続 ID、transport epoch、必要な sequence を含め、stale event を識別できるようにする。

### 購読 API

- `AsyncStream` / `AsyncThrowingStream` または明示的な executor と `@Sendable` closure を受け取る購読 API を提供する。
- 複数購読者を許可するか、1 接続 1 stream とするかを API 契約で決める。
- buffer size、overflow 時の drop 方針、購読解除、接続終了時の stream 終端を明示する。
- continuation と購読 state は接続 owner が管理し、購読者の Task cancellation で確実に解除する。

### executor と順序

- network / connection event は接続単位の ordered event stream から配送する。
- UIKit renderer と UI 専用 event だけを `@MainActor` にする。一般 event を一律 MainActor へ変更しない。
- 利用者 handler は owner の critical section 外で実行する。
- event handler から同期 getter、send、disconnect を呼べるかを明記し、許可する操作では deadlock しないことを保証する。

### legacy handler

- 既存 handler class と property の型は変更しない。
- 既存 handler は内部 event を compatibility adapter から配送する。
- 接続開始時に handler snapshot を取る場合は、開始後の差し替えが反映されるかどうかを既存挙動と照合して明文化する。
- legacy handler の deprecation と削除は本 issue に含めない。

### 他の open issue との整合

- `0035` で追加される audio session event は、raw `RTCAudioSession` を新 Sendable event payload に含めない。
- `0047` の disconnect complete event は、接続終了 event の順序と exactly-once 契約へ統合できる構造にする。
- `0027` の renderer event は MainActor 専用経路として一般 event stream と分離する。

## スコープ外

- legacy handler API の削除は次期 major version の別 issue とする。
- MainActor renderer protocol の追加は `0027` で扱う。
- raw WebRTC 型の公開 API からの撤去は `0070` と整合させる。
- RPC response API は `0109` で扱う。

## テスト方針

モックやスタブは使用しない。

- 実 Sora 接続と実 WebRTC event を、新しい event API と legacy handler の両方で購読する。
- connect、stream add、DataChannel open、message、redirect、disconnect の event 順序を記録する。
- event handler 内から同期 getter、send、disconnect を呼び、deadlock しないことを確認する。
- 購読 Task を cancel し、continuation と購読者が残留しないことを確認する。
- buffer overflow を実 event の連続発生で再現し、定義した drop / backpressure 方針どおりになることを確認する。
- 2 接続の event が connection ID / epoch で混線しないことを確認する。
- `0107` の consumer fixture から nonisolated actor と MainActor の両方で購読できることを確認する。
- テストには、event ordering、buffer 方針、reentrancy の期待を日本語コメントで明記する。

## 完了条件

- Sendable な event model と購読 API が公開されていること。
- event payload に mutable `MediaChannel`、`MediaStream`、raw WebRTC object が含まれないこと。
- event の配送 executor、順序、lifetime、buffer、購読解除契約が API documentation に記載されていること。
- Task cancellation と接続終了で購読が確実に終端すること。
- 利用者 callback を内部 owner の critical section 外で実行すること。
- UIKit 専用 event 以外を一律 MainActor へ隔離していないこと。
- legacy handler API の source compatibility が維持されること。
- legacy handler と新 event API の event 内容・順序が対応表で確認できること。
- `0035`、`0047`、`0027` の event 設計と矛盾しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
