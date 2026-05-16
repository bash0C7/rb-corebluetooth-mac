# Task 13 (Phase H — PeripheralEvent + poll_events) Handoff

**Date**: 2026-05-16
**Purpose**: 新セッションで Task 13 を熟考しながら実装する用の引き継ぎ doc
**Scope**: Phase H のみ。Task 14 以降は別 handoff 不要 (Plan 通りで進められる)

---

## 1. 現状スナップショット

- Repo: `/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac`
- HEAD: `41e54f0 fix(descriptor): private central accessor; restore CCCD assertion in HW test`
- Branch: `master`
- Tests baseline: **78 tests / 103 assertions / 0 failures / 0 errors / 22 omissions**
- 4 protected dirty files (Task 17/18 まで触らない、これは変わらず):
  - `README.md`
  - `examples/scan_only.rb`
  - `examples/scan_and_read.rb`
  - `examples/subscribe_ractor.rb`
- もう 1 つの dirty file:
  - `docs/superpowers/plans/2026-05-16-v0.2.1-data-surface-completeness.md` (ユーザ手動編集の繰越 — 触らない)

## 2. v0.2.1 完了 phase

| Phase | Task | Status | 概要 |
|-------|------|--------|------|
| A | 1-3 | ✅ | Single Error class、ErrorCodes、JSON envelope |
| B | 4-5 | ✅ | DiscoveredDevice 11-field、全 ad-data |
| C | 6 | ✅ | Characteristic 10-bits properties、`supports?` |
| D | 7-8 | ✅ | Service `is_primary` + UUID filter + `discover_included_services` |
| E | 9 | ✅ | `last_disconnect_error` + L5 fix + delegate-lookup follow-up |
| F | 10-11 | ✅ | `read_rssi` + 3-issue fix / `max_write_length` + connected-guard |
| G | 12 | ✅ | Descriptors API (discover/read/write) + encapsulation/CCCD fix |
| **H** | **13** | **🔄 次** | **PeripheralEvent + poll_events** |
| I | 14 | 残 | UUID filter HW verify only (Task 7 で実装済、HW テストのみ追加) |
| J | 15 | 残 | Central#close + L1 |
| K | 16 | ✅ | `__attribute__((noreturn))` (Task 3 で自動 close 済) |
| L | 17/18 | 残 | examples/Rakefile + README rewrite |
| M | 19 | 残 | VERSION bump + `v0.2.1` tag (push 禁止) |

## 3. Task 13 Source of Truth

- Spec: `docs/superpowers/specs/2026-05-16-v0.2.1-data-surface-completeness.md` §9 (Peripheral events), §4.4 (Peripheral surface)
- Plan: `docs/superpowers/plans/2026-05-16-v0.2.1-data-surface-completeness.md` §Task 13 (L1045-1181)

## 4. ⚠️ Plan Task 13 の発見済 Inconsistency (要解決)

Plan を素直に実装すると **動かない** 箇所 3 つ。新セッション開始時にまず確定させること。

### 4.1 Tag 表記の不整合 (3 箇所)

| 場所 | Plan 表記 | 行 |
|------|-----------|------|
| Swift enum `PeripheralEventTag` | `case nameUpdated, servicesInvalidated, disconnected` (lowerCamelCase rawValue) | L1102 |
| Swift `@c cbm_peripheral_poll_events` JSON 出力例 | `"name_updated"` (snake_case) | L1142 |
| Ruby `Peripheral#poll_events` case match | `"nameUpdated"` / `"servicesInvalidated"` / `"disconnected"` (lowerCamelCase) | L1153-1157 |

**確定方針**: **snake_case 統一** (`"name_updated"` / `"services_invalidated"` / `"disconnected"`)。理由:
- Ruby idiom (キーは snake_case が convention)
- 既存 envelope JSON も snake_case (`code_name`, `is_primary` 等)
- Swift enum は `case nameUpdated = "name_updated"` のように rawValue 明示で対応

### 4.2 Step 1 unit test の `assert_predicate e, :frozen?`

Plan L1065 に `assert_predicate e, :frozen?  # Data.define instances are not auto-frozen but value-eq` あり。コメントが矛盾を自認しており、**assertion 自体が fail する**。

**確定方針**: 該当 assertion **削除**。`test_event_classes_ractor_shareable` (L1078-1081) で shareability 検証してるので、frozen check は重複。

### 4.3 Step 8 `__call_native` の戻り値経路

Plan L1150-1163 で `__call_native(:peripheral_poll_events, ...)` の戻り値を直接 `json` として扱ってる (`json["tag"]`)。`Step 6` の Swift 側は JSON envelope `{"ok": true, "data": null}` または `{"ok": true, "data": {...}}`。

既存 `__call_native` は envelope の `data` フィールドを取り出して返す形のはず。つまり `json` は `nil` (timeout) または `{"tag": ..., "payload": ...}` (event) になる。Plan の処理は正しいが、**`return nil if json.nil?` で timeout を弾く前提を明示してる** ことを意識すること。

## 5. Task 13 確定設計

### 5.1 Files (10 件)

- **Create**: `lib/corebluetooth_mac/peripheral_event.rb`
- **Modify**: `lib/corebluetooth_mac.rb` (require 追加)
- **Modify**: `lib/corebluetooth_mac/peripheral.rb` (`#poll_events`)
- **Modify**: `lib/corebluetooth_mac/central.rb` (`__call_native` dispatcher case 1 個)
- **Modify**: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMPeripheralDelegate.swift` (event queue + sem + lock + 2 delegate methods)
- **Modify**: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift` (`didDisconnectPeripheral` で `pushEvent` 追加)
- **Modify**: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift` (`@c cbm_peripheral_poll_events`)
- **Modify**: `ext/corebluetooth_mac/corebluetooth_mac.c` (`rb_peripheral_poll_events`)
- **Create**: `test/unit/test_peripheral_event_shape.rb`
- **Create**: `test/integration/test_peripheral_events.rb`

### 5.2 Ruby API surface

```ruby
module CoreBluetoothMac
  module PeripheralEvent
    NameUpdated         = Data.define(:name)               # name: String
    ServicesInvalidated = Data.define(:uuids)              # uuids: [String]
    Disconnected        = Data.define(:error)              # error: CoreBluetoothMac::Error or nil
  end

  class Peripheral
    def poll_events(timeout: 0.0)
      # Returns PeripheralEvent::* instance or nil (timeout/no event)
    end
  end
end
```

### 5.3 Swift event queue

- per-delegate (per-peripheral) queue
- `OSAllocatedUnfairLock<PeripheralEventState>` typed lock
- queue 上限 256 (Plan L1114): overflow 時は **drop oldest** (FIFO)
- `pushEvent` from 3 sources:
  - `peripheralDidUpdateName(_:)` → `name_updated`
  - `peripheral(_:didModifyServices:)` → `services_invalidated`
  - `centralManager(_:didDisconnectPeripheral:error:)` → `disconnected` (Task 9 で SKIP した push がここで来る)
- `pollEvent(timeoutMs:)` は immediate dequeue → 失敗時 sem wait → 再 dequeue

### 5.4 JSON envelope output shape

```json
// timeout / no event
{"ok": true, "data": null}

// event
{"ok": true, "data": {
  "tag": "name_updated",
  "payload": {"name": "newname"}
}}

{"ok": true, "data": {
  "tag": "services_invalidated",
  "payload": {"uuids": ["1800", "180a"]}
}}

{"ok": true, "data": {
  "tag": "disconnected",
  "payload": {"error": null | {"domain":"...", "code":..., "code_name":"...", "message":"..."}}
}}
```

## 6. 凍結アーキ決定 (再議論不要)

- Single `Error` class、`domain:` required (`:timeout`/`:closed`/`:connection`/`:discovery`/`:validation`/`:cb`/`:att`)
- JSON envelope `{"ok"/"data"/"error"}` 全 `@c` 出力で使用
- `OSAllocatedUnfairLock<State>` typed lock
- `Int32` timeoutMs (Task 10 fix で確立)
- `@preconcurrency import CoreBluetooth` / `@unchecked Sendable`
- macOS 13+
- No v0.2.0 compat
- Conventional commits English / No Co-Authored-By trailer / No `--no-verify` / No `git push` / No destructive git

## 7. 既存 pattern reference (Task 9-12 で確立)

- **Disconnect fail-fast** (Task 10 で確立): `didDisconnectPeripheral` 内で進行中の各 operation の sem を signal + lock を `.failure(.lib(domain: "connection", ...))` で埋める。Task 13 ではこの**逆向き** — disconnect 自体が event push の source。disconnect 時の処理順序:
  1. `lastDisconnectInfo` 書き込み (Task 9 既存)
  2. 既存 ops (rssi/descriptors/etc) の sem fail-fast (Task 10/12 既存)
  3. **新規**: `pushEvent(tag: "disconnected", payload: {error: ...})`
- **Sem drain pre-call** (Task 10 で確立): `poll_events` は drain しない (event queue は累積 OK、stale signal の概念がない)。ただし `events.sem` を別ロックから参照する場合の race 注意。
- **Typed lock を最初から採用** (Plan L1014): Task 12 と同様、Result<T, CBMError>? 風に。
- **No silent rescue** (`rescue nil` 禁止): test の cleanup でも `ensure central&.close` のみ、`rescue ... => _` 禁止 (CLAUDE.md `~/dev/src/CLAUDE.md`)。

## 8. 関連 SDK header (Apple API 検証必須、memory 頼みなし)

`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreBluetooth.framework/Versions/A/Headers/`

- `CBPeripheral.h`:
  - delegate: `- (void)peripheralDidUpdateName:(CBPeripheral *)peripheral;`
  - delegate: `- (void)peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray<CBService *> *)invalidatedServices;`
- `CBCentralManager.h`:
  - delegate: `- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(nullable NSError *)error;`

(`feedback_apple_api_sources.md` 規律 — Xcode docset または上記 SDK header からのみ取得、推測しない)

## 9. Test 期待値

- Step 1 unit test (4 tests):
  - `test_name_updated_is_data`
  - `test_services_invalidated_carries_uuids`
  - `test_disconnected_carries_error`
  - `test_event_classes_ractor_shareable`
- Step 9 HW integration (1 test):
  - `test_poll_events_drains_disconnect`

baseline 78/103/0/0/22 → **82/N/0/0/23** 期待 (unit +4 tests + N assertions、HW +1 omit)

## 10. Build 注意

- Swift signature 変更後は `bundle exec rake clean clobber compile` (incremental は bridging header 古いまま)
- LSP false positive (SourceKit `Cannot find type 'CBM*'` 系) は無視。`rake compile` exit code が真実
- C 側 clangd は `rake clangd:setup` 済の `compile_flags.txt` で大幅改善 (残 noise は `*-Swift.h` indexing 遅延のみ)

## 11. 次セッション最初の 3 ステップ

1. `git -C /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac log --oneline -5` で HEAD `41e54f0` 確認
2. この doc (§4-5) で確定設計を再認識
3. Plan §Task 13 (L1045-1181) を読み、§4 の 3 つの inconsistency を念頭に implementer subagent dispatch (subagent-driven-development workflow: implementer → spec reviewer → code-quality reviewer)

### Implementer prompt の重要ポイント

- **tag は snake_case 統一**: `"name_updated"` / `"services_invalidated"` / `"disconnected"`
- **Swift enum は rawValue 明示**: `case nameUpdated = "name_updated", ...`
- **Step 1 unit test の `assert_predicate e, :frozen?` は削除**
- **`didDisconnectPeripheral` の処理順序**: Task 9/10 既存ロジックの**後**で `pushEvent(disconnected, ...)` 追加 (既存パス壊さない)
- **queue 256 上限**: overflow drop oldest、これは silent drop なので debug 時の混乱可能性あり (テスト時は queue 溢れに注意)
- **No silent rescue**: HW test の teardown は `ensure @central = nil` のみ

## 12. 関連 memory file

新セッション開始時、以下が auto-load される:

- `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-rb-corebluetooth-mac/memory/MEMORY.md`
- `project_v021_status.md` (HEAD `41e54f0`, Phase A-G 完了)
- `reference_v021_docs.md` (spec/plan/SDK header path)
- `feedback_apple_api_sources.md` (Apple API は SDK header から)

これら + 本 handoff で cold-start 可能。
