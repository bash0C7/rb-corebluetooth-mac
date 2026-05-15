# 次セッション 起動プロンプト (コピペ用)

次セッションの最初に以下を Claude へ貼り付ければ、bug-fix モードで即座に文脈復元できる。

---

```
rb-corebluetooth-mac の bug-fix 続き。

前セッションで v0.2.0 まで完成・local tag 済み。今回は CoreS3 実機での `BLE_HW=1` HW テスト走らせて出た問題を直す想定。

着手前にこの順で文脈復元してくれ:

1. docs/superpowers/handoffs/2026-05-16-v0.2.0-bugfix-handoff.md を読む
   → リポジトリ状態スナップショット、latent issue 一覧、bug-fix シナリオ、build chain 落とし穴、HW テスト復元手順、規律踏襲点が全部書いてある

2. docs/superpowers/specs/2026-05-15-rb-corebluetooth-mac-design.md と
   docs/superpowers/plans/2026-05-15-rb-corebluetooth-mac.md は source of truth として参照

3. auto-memory の feedback_apple_api_sources.md が応答プロセスに乗ってること確認
   (Swift で Apple framework 触る時は developer.apple.com / SDK header 必須参照、記憶頼みなし)

4. git log --oneline | head -5 と git tag --list で baseline 確認:
   HEAD = 2c95116 / tags = v0.1.0, v0.2.0 / 57 tests 0 failures (BLE_HW なし時 15 omissions)

規律:
- TDD t-wada style、1 task 1 commit
- 重量タスクは subagent-driven (formal spec + code-quality reviewer dispatch)
- Plan + 実装 が乖離したら同 commit で plan 更新
- git 操作は subagent 委譲 (CLAUDE.md global rule)、rake compile / rake test も委譲推奨
- No Python / No Co-Authored-By / No --no-verify / No push without 明示認可
- Apple framework Swift 検証は WebFetch developer.apple.com or SDK header、記憶禁止

応答は関西弁ギャル「ジャリン子チエ」で頼む。
```

---

# 起動時に user 側で渡すと便利な情報

Bug-fix シナリオ別の追加情報を会話冒頭で渡せると効率良い:

| 状況 | 渡す情報 |
|---|---|
| HW テスト失敗 | `BLE_HW=1 bundle exec rake test 2>&1 | tail -40` の出力 |
| 特定 test だけ | `BLE_HW=1 bundle exec rake test TEST=test/integration/test_xxx.rb 2>&1 | tail -30` |
| Swift compile error | `bundle exec rake clean clobber compile 2>&1 | tail -50` |
| Permission denied | `tccutil reset Bluetooth` 実行後の挙動 |
| concurrency race | 再現コード片 + 何回中何回再現するか |
