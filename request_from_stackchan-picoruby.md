# Requests from stackchan-picoruby (consumer-side TODO log)

`stackchan-picoruby` repo の BLE Phase 2 autonomous verification loop 構築中に出会った
rb-corebluetooth-mac 側の瑕疵 / 改善要望 / pain points を TODO 形式で記録する。

書き出し元 spec / plan:
- `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/docs/superpowers/specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md`
- `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/docs/superpowers/plans/2026-05-16-ble-mac-autonomous-verification-loop.md`

優先度: P0 (consumer 死ぬ) > P1 (回避できるが手間) > P2 (nice to have)。
status: `[ ]` (open) / `[x]` (gem 側で対応済み)。

---

## Native extension build / install 周り

- [ ] **P0: `path:` source 経由で gem を載せたとき、prebuilt `lib/corebluetooth_mac/corebluetooth_mac.bundle` が consumer 側 Ruby version と不一致だと `LoadError: linked to incompatible /Users/.../libruby.X.Y.dylib` で即死する**
  - 観測: stackchan-picoruby (pc/stackchan-protocol/Gemfile) で `gem 'rb-corebluetooth-mac', path: '...'` 指定 → `bundle install` 通る → `bundle exec ruby -r corebluetooth_mac -e ...` で上記 error
  - 直接原因: rb-corebluetooth-mac の `.ruby-version` = 4.0.3 で開発、`lib/...bundle` も 4.0.3 用にビルド済み。consumer 側が rbenv default 4.0.1 なので mismatch
  - 暫定回避 (consumer 側): `pc/stackchan-protocol/.ruby-version` に `4.0.3` を pin (stackchan-picoruby Task 2 で実施、commit de32ef5)
  - 期待挙動: gem 側で load 時に Ruby version check → mismatch なら `rake compile` を促す clear なエラー or 自動 rebuild。`extconf.rb` は gem install 時には走るが path: source では skip される (Bundler の挙動)
  - 改善案 (gem 側):
    1. `lib/corebluetooth_mac.rb` 冒頭で `RUBY_VERSION` と `.bundle` メタデータ (file -L on macOS で linked lib version 取れる) を比較し、不一致なら `Cannot load corebluetooth_mac: native ext built for Ruby X.Y, current is Y.Z. Run \`bundle exec rake compile\` in #{__dir__}` 等を raise
    2. ↑が重ければ最低限 README に「path: source 利用時は Ruby 4.0.3 を pin するか、rake compile してから使う」を明記

- [ ] **P1: `swift_gem` runtime dependency が rubygems.org に未公開で、consumer Gemfile に追加 path: 指定が必須**
  - 観測: stackchan-picoruby Task 1 で `gem 'rb-corebluetooth-mac', path: '...'` だけ書いて `bundle install` → `Could not find swift_gem` で失敗 → consumer 側 Gemfile に `gem 'swift_gem', path: '/Users/bash/dev/src/github.com/bash0C7/swift_gem'` を追加して回避 (stackchan-picoruby Task 1 commit 38b426a)
  - 期待挙動: swift_gem は rubygems.org に publish されているか、もしくは rb-corebluetooth-mac の gemspec 側で何らかの形 (git source など) で transitive 解決される
  - 改善案:
    1. swift_gem を rubygems.org に release (一番すっきり)
    2. 困難なら README "Installation" に「同時に swift_gem も path/git で Gemfile に追加する必要がある」を明記し、想定 path 例も書く

---

## API / contract レベル (Plan 進行中に追記予定)

- [ ] **P2: Apple CoreBluetooth が GAP (0x1800) / GATT (0x1801) services を `discoverServices(nil)` から filter する仕様を README に明記してほしい**
  - 観測: peripheral.discover_services(timeout:) 後 `peripheral.services` を見ると、device 側 att_db には GAP / FFE0 / NUS の 3 services あるのに、Mac 側は **FFE0 / NUS の 2 services しか返さない**
  - 直接原因: Apple platform 仕様。`peripheral.discover_services` 経由では 0x1800 / 0x1801 が露出しない (Apple が internal/implementation-level として扱う)
  - 暫定回避 (consumer 側): device 名は `device.name` (DiscoveredDevice の scan-response advertising local name) から取り、`assert_services` から 0x1800 を除外 (stackchan-picoruby 側で対応済み)
  - 期待挙動: gem 側仕様変更ではなく、 README "Limitations" などに以下を追記
    > **Apple CoreBluetooth filters GAP (0x1800) and GATT (0x1801) services from `discoverServices(nil)`.**
    > Their characteristics (e.g. Device Name 0x2a00, Appearance 0x2a01) are not reachable via `find_characteristic`.
    > Use `device.name` from `Central#scan` results for the advertised local name. For other GAP/GATT chars, use platform-specific replacements (e.g. peripheral.name / peripheral identifier).
  - 改善案: 上記 README 追記 1 つで十分 (API 変更不要)。`Peripheral#name` accessor を追加するなら CBPeripheral.name を露出する形になる (CoreBluetooth が advertisement local name か cached GAP name を返す)。

---

## Documentation / DX

- [ ] **P2: README の subscribe 例が Ractor 必須に見える**
  - 観測: README の "Subscribing to notifications (Ractor pump)" セクションが Ractor を使う長い例しか無く、`Subscription#next_value` を main thread から直接呼べることが説明文の片隅 ("common pattern is to run the polling loop in a Ractor") からしか読み取れない
  - 期待挙動: 「main thread から直接 `sub.next_value(timeout:)` を呼ぶシンプル例」も並べる (Ractor 不要のユースケースのほうが多いはず)
  - 改善案: subscribe セクションに 2 つの例 (シンプル / Ractor) を並べる、もしくは「最小例」を先に出して「並列で受けたいなら Ractor」を後段に置く

---

## ログ / debugging

(必要に応じて追記)

---

## このファイルの運用

- stackchan-picoruby Phase 2 開発を進めながら気づくたびに append
- rb-corebluetooth-mac 側で対応されたら `[ ]` → `[x]` に更新 + 該当 gem 側 commit SHA を memo
- request が全部捌けたら、このファイルを削除するか archive に移す
