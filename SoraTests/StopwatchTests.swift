import XCTest

@testable import Sora

/// `Utilities.Stopwatch` の観測可能な挙動に関するユニットテスト
///
/// モックやスタブは使用せず、実 `Stopwatch` と実 `Timer` (main RunLoop) だけを使う。
/// `run()` は `timer.fire()` を呼び、`fire()` は closure を同期実行するため、初回の通知は
/// wall clock に依存せず決定的に観測できる。1 秒ごとの通知は wall clock と RunLoop の実行に
/// 依存するため、通知の回数を厳密に比較せず「文字列が進むこと」だけを確認する。
final class StopwatchTests: XCTestCase {
  /// run() の直後の同期通知と、run() の再呼び出しによる経過秒数の 0 リセットを確認する
  ///
  /// run() は timer.fire() を呼び、fire() は closure を同期実行する。このため run() から
  /// 戻った時点で 1 回目の通知 "00:00:00" を観測でき、wall clock に依存しない。seconds は
  /// private のため直接は観測できないが、2 回目の run() の最初の通知が "00:00:00" に戻る
  /// ことで 0 リセットを観測する (リセットが無ければ "00:00:01" になる)。
  func testRunNotifiesImmediatelyAndResetsSeconds() {
    var notifications: [String] = []
    let stopwatch = Utilities.Stopwatch { text in
      notifications.append(text)
    }
    // 停止し忘れると Timer が main RunLoop に残り、後続のテストへ通知が漏れる。
    defer { stopwatch.stop() }

    // run() の 1 回目は "00:00:00" を通知した後に経過秒数を 1 へ進める。
    // 2 回目の run() は経過秒数を 0 に戻してから通知する。
    stopwatch.run()
    stopwatch.run()

    XCTAssertEqual(
      notifications, ["00:00:00", "00:00:00"],
      "run() の直後に \"00:00:00\" が 1 回通知され、run() の再呼び出しで経過秒数が 0 に戻ること")
  }

  /// stop() の後に通知が増えないことを確認する
  ///
  /// stop() は timer?.invalidate() を呼ぶ。invalidate 済みの Timer は RunLoop から
  /// 削除され、以降の発火で closure を実行しない。停止後の通知が同期通知の 1 回だけに
  /// 留まることを確認する。
  func testStopStopsNotifications() {
    var notifications: [String] = []
    let stopwatch = Utilities.Stopwatch { text in
      notifications.append(text)
    }
    defer { stopwatch.stop() }

    stopwatch.run()
    stopwatch.stop()

    // 停止後も main RunLoop を回し、invalidate 済み Timer が通知しないことを確認する。
    // 待ち時間は Timer の 1 周期 (1 秒) を確実に超える長さにする。
    let expectation = self.expectation(description: "停止後の経過を待つこと")
    // 2 回目以降の fulfill を失敗として検出する
    expectation.assertForOverFulfill = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)

    XCTAssertEqual(
      notifications, ["00:00:00"],
      "stop() の直後の同期通知を除いて通知が増えないこと")
  }

  /// 1 秒経過で通知の文字列が進むことを確認する
  ///
  /// 1 秒ごとの発火は wall clock と RunLoop の実行に依存する。通知の文字列は発火のたびに
  /// 1 つ進むため、2 回目の通知は "00:00:01" になる。通知の回数は比較せず、最初の
  /// "00:00:00" の後に "00:00:01" が届くことだけを確認する。1 回だけ届くことは
  /// assertForOverFulfill で検出する (通知が進まない退行は timeout で、同じ文字列が 2 回
  /// 届く退行は 2 回目の fulfill として検出する)。
  func testSecondsIncreaseAfterOneSecond() {
    let expectation = self.expectation(description: "1 秒経過の通知を待つこと")
    // 2 回目以降の fulfill を失敗として検出する
    expectation.assertForOverFulfill = true
    let stopwatch = Utilities.Stopwatch { text in
      if text == "00:00:01" {
        expectation.fulfill()
      }
    }
    defer { stopwatch.stop() }

    stopwatch.run()
    wait(for: [expectation], timeout: 10)
  }

  /// 利用者の handler から stop() を呼んでも deadlock しないことを確認する
  ///
  /// stop() は timer?.invalidate() を lock 区間の外で呼び、その後に storage の lock を取って
  /// 経過秒数を 0 に戻す。handler は lock 区間の外で呼ぶ契約のため、handler からの stop() は
  /// storage の lock を解放した状態で完了し、通知は同期通知の 1 回だけになる。handler を
  /// lock 区間の中で呼ぶ実装へ退行すると、再入した stop() が同じ非再帰 lock を再取得して
  /// deadlock する。deadlock は XCTest の timeout では検出できず、このテストは
  /// wait(for:timeout:) を挟んでも返らないままハングする。
  func testHandlerCanCallStopReentrantly() {
    var notifications: [String] = []
    var stopwatch: Utilities.Stopwatch?
    stopwatch = Utilities.Stopwatch { text in
      notifications.append(text)
      // lock 区間の外で呼ばれる handler からの再入。ここで deadlock するとテストが停止する。
      stopwatch?.stop()
    }
    // Timer を停止してから、再入のために closure が捕捉した参照を解放し、循環参照を残さない。
    defer {
      stopwatch?.stop()
      stopwatch = nil
    }

    stopwatch?.run()

    XCTAssertEqual(
      notifications, ["00:00:00"],
      "handler からの stop() が完了し、通知が同期通知の 1 回だけであること")
  }

  /// 利用者の handler から run() を呼んでも deadlock しないことを確認する
  ///
  /// run() は timer.fire() を呼び、fire() は closure を同期実行する。handler は lock 区間の
  /// 外で呼ぶ契約のため、handler からの run() は storage の lock を解放した状態で再入し、
  /// 再入した run() の fire() が closure をもう一度同期実行して 2 回目の通知 "00:00:00" を
  /// 届ける。この再入が起きることは、通知が 2 回であることで確認する (再入が起きなければ
  /// このテストは deadlock の回帰を検出できない)。handler を lock 区間の中で呼ぶ実装へ
  /// 退行すると、再入した run() の storage の lock 取得が同じ非再帰 lock の再取得になり
  /// deadlock する。deadlock は XCTest の timeout では検出できず、このテストは
  /// wait(for:timeout:) を挟んでも返らないままハングする。
  func testHandlerCanCallRunReentrantly() {
    var notifications: [String] = []
    var didReenter = false
    var stopwatch: Utilities.Stopwatch?
    stopwatch = Utilities.Stopwatch { text in
      notifications.append(text)
      // 再入は 1 回で止める。fire() の再入をそのまま繰り返すと無限再帰になるため。
      guard !didReenter else {
        return
      }
      didReenter = true
      // lock 区間の外で呼ばれる handler からの fire() の同期再入。
      stopwatch?.run()
    }
    // Timer を停止してから、再入のために closure が捕捉した参照を解放し、循環参照を残さない。
    defer {
      stopwatch?.stop()
      stopwatch = nil
    }

    stopwatch?.run()

    XCTAssertEqual(
      notifications, ["00:00:00", "00:00:00"],
      "handler からの run() が再入し、2 回目の同期通知が届くこと")
  }
}
