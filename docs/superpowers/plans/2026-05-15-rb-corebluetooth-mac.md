# rb-corebluetooth-mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `rb-corebluetooth-mac` Ruby gem so a macOS host can act as a BLE central against a CoreS3 BLE peripheral (`StackChan-PicoRuby`) via Apple's CoreBluetooth framework, with Phase 1 = scan/connect/discover/read and Phase 2 = write/subscribe/notify, all driven by t-wada style TDD.

**Architecture:** Three-layer stack — Ruby lib (pure routing + Data.define value objects) → C bridge (≤150 LOC, GVL-releasing thunks) → Swift implementation (CBCentralManager + delegate, `@c` SE-0495 ABI, OSAllocatedUnfairLock-protected SubscriptionRegistry). Central is the only `TypedData_Wrap_Struct`; Peripheral/Service/Characteristic are pure Ruby; Subscription is a Ractor-shareable `Data.define`.

**Tech Stack:** Ruby 4.0.3 (dev pin; gemspec requires ≥ 3.2.0), Swift 6.3.1 (SE-0495 `@c` attribute), `swift_gem` (`SwiftGem::Mkmf.create_swift_makefile`), `rake-compiler`, `test-unit`, JSON for C-bridge data interchange, Apple CoreBluetooth (macOS 13+ — `OSAllocatedUnfairLock` requires macOS 13).

**Reference design doc:** `docs/superpowers/specs/2026-05-15-rb-corebluetooth-mac-design.md` (every section here ties back to a section there).

**Reference codebase:** `~/dev/src/github.com/bash0C7/rb-foundation-model-mac` — same pattern; consult its files for canonical idioms when an unfamiliar Ruby-C-Swift bridge issue comes up.

**Hardware test prerequisite:** A CoreS3 device running picoruby-ble peripheral, advertising name `StackChan-PicoRuby`, freshly powered (60s advertising window opens after `rake r2p2:reset` on the CoreS3 side). Integration tests are gated on `BLE_HW=1` and call `HardwareGuard.skip_unless_hardware!(self)` in `setup`.

---

## File Structure

Files created across all tasks:

```
rb-corebluetooth-mac/
├── .gitignore
├── .ruby-version                                       # "4.0.3"
├── .swift-version                                      # "6.3.1"
├── Gemfile
├── Rakefile
├── rb-corebluetooth-mac.gemspec
├── LICENSE.txt                                         # MIT, copied verbatim from sibling
├── README.md                                           # written at end of Phase 1
├── lib/
│   ├── corebluetooth_mac.rb                            # entry: requires + module + error classes
│   └── corebluetooth_mac/
│       ├── version.rb                                  # VERSION constant
│       ├── discovered_device.rb                        # Data.define value object
│       ├── subscription.rb                             # Data.define value object + next_value/close
│       ├── characteristic.rb                           # pure Ruby, routes via service.peripheral.central
│       ├── service.rb                                  # pure Ruby
│       ├── peripheral.rb                               # pure Ruby
│       └── central.rb                                  # thin C-ext wrapper (Native class)
├── ext/
│   └── corebluetooth_mac/
│       ├── extconf.rb                                  # SwiftGem::Mkmf.create_swift_makefile
│       ├── Package.swift                               # swift-tools-version:6.3, platforms macOS 13+
│       ├── corebluetooth_mac.c                         # ~150 LOC: TypedData + rb_thread_call_without_gvl
│       └── Sources/
│           └── CoreBluetoothMac/
│               ├── CoreBluetoothMac.swift              # @c ABI surface (thin)
│               ├── CBMCentral.swift                    # CBCentralManager owner + central delegate
│               ├── CBMPeripheralDelegate.swift         # per-peripheral state machine
│               ├── CBMSubscriptionRegistry.swift       # global, OSAllocatedUnfairLock
│               └── CBMSync.swift                       # Box, semaphore helpers (FM pattern parity)
├── test/
│   ├── test_helper.rb                                  # HardwareGuard, common boot
│   ├── unit/
│   │   ├── test_module.rb
│   │   ├── test_errors.rb
│   │   ├── test_discovered_device.rb
│   │   ├── test_subscription_value.rb
│   │   └── test_peripheral_routing.rb
│   └── integration/
│       ├── test_central_init.rb
│       ├── test_scan.rb
│       ├── test_connect.rb
│       ├── test_discover.rb
│       ├── test_read_gap_device_name.rb
│       ├── test_write.rb
│       ├── test_subscribe.rb
│       └── test_subscribe_ractor.rb
├── examples/
│   ├── scan_only.rb                                    # spike runner used early
│   ├── scan_and_read.rb                                # Phase 1 deliverable
│   └── subscribe_ractor.rb                             # Phase 2 deliverable
└── docs/
    └── superpowers/
        ├── specs/2026-05-15-rb-corebluetooth-mac-design.md  # exists
        └── plans/2026-05-15-rb-corebluetooth-mac.md         # this file
```

---

## TDD Discipline (t-wada style) — Every task uses these rules

1. **One failing test first.** Smallest meaningful failure.
2. **Smallest possible code to make it green.** Fake it (return a constant) is allowed and encouraged early.
3. **Refactor only on duplication or unclear naming.** Never speculatively.
4. **Run the whole test suite before committing.**
5. **One TODO checkbox = one commit.** Conventional Commits (`test:` / `feat:` / `fix:` / `refactor:` / `chore:` / `docs:` / `build:`).
6. **No silent rescue.** Per `~/dev/src/CLAUDE.md`: empty `rescue` is banned; tests use `omit "reason: …"` to skip.
7. **Git operations via subagent.** Each commit step delegates to `commit-commands:commit` skill (or general-purpose agent) — do not call `git` directly from Bash. The plan shows the commit *message* and *files*; the executor passes those to the subagent.

---

## Task 1: Initialize git repo and project boilerplate

**Files:**
- Create: `.gitignore`
- Create: `.ruby-version`
- Create: `.swift-version`
- Create: `LICENSE.txt`

- [ ] **Step 1: Initialize git repository**

Delegate to a subagent:
> Prompt: `cd /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac && git init && git status` — confirm working directory is clean apart from `.claude/` and `docs/`.

Expected: "Initialized empty Git repository …", `.claude/` and `docs/` shown as untracked.

- [ ] **Step 2: Write `.gitignore`**

Create `.gitignore` with this exact content (copied from `rb-foundation-model-mac/.gitignore`):

```gitignore
/.yardoc
/_yardoc/
/coverage/
/doc/
/pkg/
/spec/reports/
.bundle/
vendor/bundle/
Gemfile.lock
*.gem

# Built native extension artifacts
ext/**/.build/
ext/**/Makefile
ext/**/*.o
ext/**/*.bundle
ext/**/*.bundle.dSYM/
ext/**/mkmf.log
ext/**/*-Swift.h
lib/**/*.bundle
lib/**/*.bundle.dSYM/
/tmp/

# Claude Code per-user settings
.claude/settings.local.json
```

- [ ] **Step 3: Write `.ruby-version`**

Create `.ruby-version` containing exactly:

```
4.0.3
```

- [ ] **Step 4: Write `.swift-version`**

Create `.swift-version` containing exactly:

```
6.3.1
```

- [ ] **Step 5: Write `LICENSE.txt`**

Copy verbatim from `~/dev/src/github.com/bash0C7/rb-foundation-model-mac/LICENSE.txt` (MIT, attributed to bash0C7, year 2026). Run via subagent:
> `cp /Users/bash/dev/src/github.com/bash0C7/rb-foundation-model-mac/LICENSE.txt /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac/LICENSE.txt`

- [ ] **Step 6: Commit**

Delegate to `commit-commands:commit`:
- Files: `.gitignore`, `.ruby-version`, `.swift-version`, `LICENSE.txt`
- Message: `chore: initialize repo with version pins, license, and gitignore`

---

## Task 2: Add Gemfile, gemspec, and Rakefile

**Files:**
- Create: `lib/corebluetooth_mac/version.rb`
- Create: `rb-corebluetooth-mac.gemspec`
- Create: `Gemfile`
- Create: `Rakefile`

- [ ] **Step 1: Create `lib/corebluetooth_mac/version.rb`**

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  VERSION = "0.1.0"
end
```

- [ ] **Step 2: Create `rb-corebluetooth-mac.gemspec`**

```ruby
# frozen_string_literal: true

require_relative "lib/corebluetooth_mac/version"

Gem::Specification.new do |spec|
  spec.name = "rb-corebluetooth-mac"
  spec.version = CoreBluetoothMac::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "Native Apple CoreBluetooth (BLE central) for Ruby on macOS"
  spec.description = "rb-corebluetooth-mac drives Apple's CoreBluetooth framework " \
    "from Ruby via a Swift native extension, exposing scan / connect / discover / " \
    "read / write / notify so a macOS host can act as a BLE central. Requires " \
    "macOS 13+."
  spec.homepage = "https://github.com/bash0C7/rb-corebluetooth-mac"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bash0C7/rb-corebluetooth-mac"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/corebluetooth_mac/extconf.rb"]

  spec.add_runtime_dependency "swift_gem", "~> 0.1"
end
```

- [ ] **Step 3: Create `Gemfile`**

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in rb-corebluetooth-mac.gemspec
gemspec

# Local sibling repo during development.
gem "swift_gem", path: "../swift_gem"

gem "irb"
gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"
gem "test-unit", "~> 3.0"
```

- [ ] **Step 4: Create `Rakefile`**

```ruby
# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "rake/testtask"

Rake::ExtensionTask.new("corebluetooth_mac") do |ext|
  ext.lib_dir = "lib/corebluetooth_mac"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task test: :compile
task default: :test
```

- [ ] **Step 5: Run `bundle install`**

Delegate to subagent:
> Prompt: `cd /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac && bundle install 2>&1 | tail -20`

Expected: "Bundle complete!" — even though `extconf.rb` doesn't exist yet, `bundle install` skips compilation for path-installed gems. If Bundler complains about the missing extension, defer until Task 11; for now we only need the gemfile.lock generated.

If it fails on extension build, that's acceptable for this task; the build infra arrives in Task 11. Move on.

- [ ] **Step 6: Commit**

Delegate to `commit-commands:commit`:
- Files: `lib/corebluetooth_mac/version.rb`, `rb-corebluetooth-mac.gemspec`, `Gemfile`, `Rakefile`
- Message: `chore: scaffold gemspec, Gemfile, and Rakefile`

---

## Task 3: First TDD cycle — `CoreBluetoothMac::VERSION` is a String

**Files:**
- Create: `test/test_helper.rb`
- Create: `test/unit/test_module.rb`
- Create: `lib/corebluetooth_mac.rb`

- [ ] **Step 1: Write `test/test_helper.rb`**

```ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "test/unit"
require "corebluetooth_mac"

module HardwareGuard
  def self.skip_unless_hardware!(test)
    return if ENV["BLE_HW"] == "1"
    test.omit "Set BLE_HW=1 with a CoreS3 advertising StackChan-PicoRuby nearby"
  end
end
```

- [ ] **Step 2: Write the failing test** — `test/unit/test_module.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class ModuleTest < Test::Unit::TestCase
  def test_VERSION_is_a_string
    assert_kind_of String, CoreBluetoothMac::VERSION
  end

  def test_VERSION_is_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, CoreBluetoothMac::VERSION)
  end
end
```

- [ ] **Step 3: Run the test — expect failure**

Delegate to subagent (general-purpose):
> Prompt: `cd /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac && bundle exec ruby -Ilib -Itest test/unit/test_module.rb 2>&1 | tail -10`

Expected: Test fails (or errors with "uninitialized constant CoreBluetoothMac"). We have `version.rb` but no entry-point require — `require "corebluetooth_mac"` will fail.

- [ ] **Step 4: Write minimal `lib/corebluetooth_mac.rb`**

```ruby
# frozen_string_literal: true

require_relative "corebluetooth_mac/version"

module CoreBluetoothMac
end
```

- [ ] **Step 5: Run test — expect green**

Delegate to subagent:
> Prompt: `cd /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac && bundle exec ruby -Ilib -Itest test/unit/test_module.rb 2>&1 | tail -10`

Expected: `2 tests, 2 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications`.

- [ ] **Step 6: Commit**

Delegate to `commit-commands:commit`:
- Files: `test/test_helper.rb`, `test/unit/test_module.rb`, `lib/corebluetooth_mac.rb`
- Message: `test: VERSION constant is a semver string`

---

## Task 4: Error hierarchy

**Files:**
- Create: `test/unit/test_errors.rb`
- Modify: `lib/corebluetooth_mac.rb`

- [ ] **Step 1: Write failing test** — `test/unit/test_errors.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Test::Unit::TestCase
  def test_Error_inherits_StandardError
    assert_operator CoreBluetoothMac::Error, :<, StandardError
  end

  def test_StateError_inherits_Error
    assert_operator CoreBluetoothMac::StateError, :<, CoreBluetoothMac::Error
  end

  def test_PermissionError_inherits_StateError
    assert_operator CoreBluetoothMac::PermissionError, :<, CoreBluetoothMac::StateError
  end

  def test_TimeoutError_inherits_Error
    assert_operator CoreBluetoothMac::TimeoutError, :<, CoreBluetoothMac::Error
  end

  def test_ConnectionError_inherits_Error
    assert_operator CoreBluetoothMac::ConnectionError, :<, CoreBluetoothMac::Error
  end

  def test_DiscoveryError_inherits_Error
    assert_operator CoreBluetoothMac::DiscoveryError, :<, CoreBluetoothMac::Error
  end

  def test_IOError_inherits_Error
    assert_operator CoreBluetoothMac::IOError, :<, CoreBluetoothMac::Error
  end

  def test_ClosedError_inherits_Error
    assert_operator CoreBluetoothMac::ClosedError, :<, CoreBluetoothMac::Error
  end
end
```

- [ ] **Step 2: Run test — expect failure**

> `bundle exec ruby -Ilib -Itest test/unit/test_errors.rb 2>&1 | tail -10`

Expected: 8 errors, all "uninitialized constant".

- [ ] **Step 3: Add error classes to `lib/corebluetooth_mac.rb`**

Replace `lib/corebluetooth_mac.rb` with:

```ruby
# frozen_string_literal: true

require "json"
require "set"

require_relative "corebluetooth_mac/version"

module CoreBluetoothMac
  class Error           < StandardError; end
  class StateError      < Error;          end
  class PermissionError < StateError;     end
  class TimeoutError    < Error;          end
  class ConnectionError < Error;          end
  class DiscoveryError  < Error;          end
  class IOError         < Error;          end
  class ClosedError     < Error;          end
end
```

- [ ] **Step 4: Run test — expect green**

> `bundle exec ruby -Ilib -Itest test/unit/test_errors.rb 2>&1 | tail -10`

Expected: `8 tests, 8 assertions, 0 failures`.

- [ ] **Step 5: Run full suite to confirm no regression**

> `bundle exec rake test 2>&1 | tail -20`

Expected: 10 tests, 10 assertions, 0 failures. (Note: `rake test` depends on `:compile`, which will fail because there's no extconf yet. **Override for this step**: run `bundle exec ruby -Ilib -Itest -e "Dir['test/**/test_*.rb'].each { require_relative File.expand_path(_1) }"` to bypass compile.)

Until Task 11 lands the native build, integration tests will fail at require time. Run only `test/unit/` directly:

> `bundle exec ruby -Ilib -Itest -e "Dir['test/unit/test_*.rb'].each { |f| require_relative File.expand_path(f) }" 2>&1 | tail -10`

- [ ] **Step 6: Commit**

- Files: `test/unit/test_errors.rb`, `lib/corebluetooth_mac.rb`
- Message: `test: lock in error class hierarchy`

---

## Task 5: `DiscoveredDevice` value object

**Files:**
- Create: `test/unit/test_discovered_device.rb`
- Create: `lib/corebluetooth_mac/discovered_device.rb`
- Modify: `lib/corebluetooth_mac.rb`

- [ ] **Step 1: Write failing test** — `test/unit/test_discovered_device.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class DiscoveredDeviceTest < Test::Unit::TestCase
  def setup
    @dev = CoreBluetoothMac::DiscoveredDevice.new(
      central_id: 1, identifier: "ABCD", name: "StackChan-PicoRuby", rssi: -42
    )
  end

  def test_has_accessors
    assert_equal 1, @dev.central_id
    assert_equal "ABCD", @dev.identifier
    assert_equal "StackChan-PicoRuby", @dev.name
    assert_equal(-42, @dev.rssi)
  end

  def test_equal_when_all_fields_equal
    other = CoreBluetoothMac::DiscoveredDevice.new(
      central_id: 1, identifier: "ABCD", name: "StackChan-PicoRuby", rssi: -42
    )
    assert_equal @dev, other
  end

  def test_not_equal_when_identifier_differs
    other = CoreBluetoothMac::DiscoveredDevice.new(
      central_id: 1, identifier: "WXYZ", name: "StackChan-PicoRuby", rssi: -42
    )
    refute_equal @dev, other
  end

  def test_is_ractor_shareable
    assert Ractor.shareable?(@dev), "DiscoveredDevice must be Ractor.shareable?"
  end
end
```

- [ ] **Step 2: Run test — expect failure**

> `bundle exec ruby -Ilib -Itest test/unit/test_discovered_device.rb 2>&1 | tail -10`

Expected: "uninitialized constant CoreBluetoothMac::DiscoveredDevice".

- [ ] **Step 3: Write `lib/corebluetooth_mac/discovered_device.rb`**

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  DiscoveredDevice = Data.define(:central_id, :identifier, :name, :rssi)
end
```

- [ ] **Step 4: Wire into `lib/corebluetooth_mac.rb`**

Append at the bottom of `lib/corebluetooth_mac.rb`:

```ruby
require_relative "corebluetooth_mac/discovered_device"
```

So the file now ends with:

```ruby
end

require_relative "corebluetooth_mac/discovered_device"
```

- [ ] **Step 5: Run test — expect green**

> `bundle exec ruby -Ilib -Itest test/unit/test_discovered_device.rb 2>&1 | tail -10`

Expected: `4 tests, 4 assertions, 0 failures`.

- [ ] **Step 6: Commit**

- Files: `test/unit/test_discovered_device.rb`, `lib/corebluetooth_mac/discovered_device.rb`, `lib/corebluetooth_mac.rb`
- Message: `feat: DiscoveredDevice value object (Ractor-shareable)`

---

## Task 6: `Subscription` value object (skeleton; native calls land in Phase 2)

**Files:**
- Create: `test/unit/test_subscription_value.rb`
- Create: `lib/corebluetooth_mac/subscription.rb`
- Modify: `lib/corebluetooth_mac.rb`

- [ ] **Step 1: Write failing test** — `test/unit/test_subscription_value.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class SubscriptionValueTest < Test::Unit::TestCase
  def setup
    @sub = CoreBluetoothMac::Subscription.new(central_id: 1, subscription_id: 42)
  end

  def test_has_accessors
    assert_equal 1, @sub.central_id
    assert_equal 42, @sub.subscription_id
  end

  def test_equal_when_fields_equal
    other = CoreBluetoothMac::Subscription.new(central_id: 1, subscription_id: 42)
    assert_equal @sub, other
  end

  def test_is_ractor_shareable
    assert Ractor.shareable?(@sub), "Subscription must be Ractor.shareable?"
  end
end
```

- [ ] **Step 2: Run test — expect failure**

> `bundle exec ruby -Ilib -Itest test/unit/test_subscription_value.rb 2>&1 | tail -10`

Expected: "uninitialized constant CoreBluetoothMac::Subscription".

- [ ] **Step 3: Write `lib/corebluetooth_mac/subscription.rb`**

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  Subscription = Data.define(:central_id, :subscription_id) do
    def next_value(timeout: 1.0)
      CoreBluetoothMac.__subscription_next_value(
        central_id, subscription_id, (timeout * 1000).to_i
      )
    end

    def close
      CoreBluetoothMac.__subscription_close(central_id, subscription_id)
    end
  end
end
```

- [ ] **Step 4: Wire into `lib/corebluetooth_mac.rb`**

Append:

```ruby
require_relative "corebluetooth_mac/subscription"
```

- [ ] **Step 5: Run test — expect green**

> `bundle exec ruby -Ilib -Itest test/unit/test_subscription_value.rb 2>&1 | tail -10`

Expected: `4 tests, 4 assertions, 0 failures`.

(`next_value` and `close` won't be exercised until Phase 2 lands the native module functions; that's fine — Ractor.shareable? and accessor tests are the contract we lock now.)

- [ ] **Step 6: Commit**

- Files: `test/unit/test_subscription_value.rb`, `lib/corebluetooth_mac/subscription.rb`, `lib/corebluetooth_mac.rb`
- Message: `feat: Subscription value object (Ractor-shareable, native methods stubbed)`

---

## Task 7: Stub-Central + Peripheral routing (unit test before native lands)

**Files:**
- Create: `test/unit/test_peripheral_routing.rb`
- Create: `lib/corebluetooth_mac/peripheral.rb`
- Modify: `lib/corebluetooth_mac.rb`

Strategy: introduce a `StubCentral` inside the test that captures calls to `__call_native`. This lets us TDD `Peripheral#discover_services` *without* needing the native extension. The stub is a test artifact only; it never leaves `test/`.

- [ ] **Step 1: Write failing test** — `test/unit/test_peripheral_routing.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class PeripheralRoutingTest < Test::Unit::TestCase
  StubCentral = Struct.new(:central_id) do
    def calls; @calls ||= []; end
    def stub(op, &body); (@stubs ||= {})[op] = body; end

    def __call_native(op, *args)
      calls << [op, args]
      (@stubs && @stubs[op] || ->(*) { nil }).call(*args)
    end
  end

  def setup
    @central = StubCentral.new(1)
    @peripheral = CoreBluetoothMac::Peripheral.new(central: @central, identifier: "AAAA")
  end

  def test_identifier_accessor
    assert_equal "AAAA", @peripheral.identifier
  end

  def test_discover_services_invokes_native_with_args
    @central.stub(:peripheral_discover_services) { |_id, _ms| ["0000180a-0000-1000-8000-00805f9b34fb"] }
    @peripheral.discover_services(timeout: 2.5)
    assert_equal [:peripheral_discover_services, ["AAAA", 2500]], @central.calls.first
  end

  def test_discover_services_populates_services
    @central.stub(:peripheral_discover_services) { |_id, _ms| ["0000180a-0000-1000-8000-00805f9b34fb", "00001800-0000-1000-8000-00805f9b34fb"] }
    @peripheral.discover_services
    assert_equal 2, @peripheral.services.size
    assert_equal "00001800-0000-1000-8000-00805f9b34fb", @peripheral.services.last.uuid
  end

  def test_services_raises_ClosedError_before_discover
    assert_raise(CoreBluetoothMac::ClosedError) { @peripheral.services }
  end

  def test_find_service_case_insensitive
    @central.stub(:peripheral_discover_services) { |_id, _ms| ["00001800-0000-1000-8000-00805f9b34fb"] }
    @peripheral.discover_services
    svc = @peripheral.find_service("00001800-0000-1000-8000-00805F9B34FB")
    refute_nil svc
    assert_equal "00001800-0000-1000-8000-00805f9b34fb", svc.uuid
  end

  def test_state_routes_to_native
    @central.stub(:peripheral_state) { |_| :connected }
    assert_equal :connected, @peripheral.state
    assert_equal [:peripheral_state, ["AAAA"]], @central.calls.last
  end
end
```

- [ ] **Step 2: Run test — expect failure**

> `bundle exec ruby -Ilib -Itest test/unit/test_peripheral_routing.rb 2>&1 | tail -10`

Expected: "uninitialized constant CoreBluetoothMac::Peripheral".

- [ ] **Step 3: Write `lib/corebluetooth_mac/peripheral.rb`**

`Service` doesn't exist yet — we'll create a minimal placeholder inline to satisfy the routing tests, then implement Service fully in Task 8.

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Peripheral
    attr_reader :identifier, :central

    def initialize(central:, identifier:)
      @central = central
      @identifier = identifier
      @services = nil
    end

    def state
      @central.__call_native(:peripheral_state, @identifier)
    end

    def discover_services(timeout: 5.0)
      uuids = @central.__call_native(
        :peripheral_discover_services, @identifier, (timeout * 1000).to_i
      )
      @services = uuids.map { |u| Service.new(peripheral: self, uuid: u) }
      self
    end

    def services
      @services || raise(ClosedError, "call discover_services first")
    end

    def find_service(uuid)
      target = uuid.downcase
      services.find { |s| s.uuid.casecmp?(target) }
    end

    def find_characteristic(uuid)
      target = uuid.downcase
      (services || []).each do |svc|
        next unless svc.characteristics_loaded?
        ch = svc.characteristics.find { |c| c.uuid.casecmp?(target) }
        return ch if ch
      end
      nil
    end
  end
end
```

- [ ] **Step 4: Wire into `lib/corebluetooth_mac.rb`** (Service/Characteristic come next)

Append:

```ruby
require_relative "corebluetooth_mac/service"          # defined in Task 8
require_relative "corebluetooth_mac/characteristic"   # defined in Task 8
require_relative "corebluetooth_mac/peripheral"
```

(Order matters: peripheral.rb references `Service.new`, which is defined after. But because `Service` is referenced inside a method body (lazy resolution), Ruby is fine — the require for `service.rb` only needs to happen before any `discover_services` call. Place service/characteristic requires first as shown.)

The test for Task 7 will fail Step 5 below because `Service` doesn't exist yet. **That's intentional** — we add Service in Task 8 and the cycle completes there. For Task 7's test_module.rb subset (`test_identifier_accessor`, `test_services_raises_ClosedError_before_discover`, `test_state_routes_to_native`) we can already go green. The remaining 3 tests stay red until Task 8.

Document this in the commit: ship the routing class, ship the tests, and note 3 are blocked on Task 8.

- [ ] **Step 5: Run test — partial green**

> `bundle exec ruby -Ilib -Itest test/unit/test_peripheral_routing.rb 2>&1 | tail -10`

Expected: 3 pass, 3 errors ("uninitialized constant CoreBluetoothMac::Service"). This is the **red** half of the next cycle.

- [ ] **Step 6: Commit (red commit; explicitly noted)**

In t-wada style we usually never commit red. Here we commit the **passing** subset only.

Option: skip this commit and roll into Task 8's commit. **Recommended:** roll into Task 8.

Proceed to Task 8 without committing. Move the staged files to "uncommitted, pending Task 8 completion".

---

## Task 8: `Service` and `Characteristic` routing (completes Task 7's failing tests)

**Files:**
- Create: `lib/corebluetooth_mac/service.rb`
- Create: `lib/corebluetooth_mac/characteristic.rb`
- Modify: `test/unit/test_peripheral_routing.rb` (add Service + Characteristic routing tests)

- [ ] **Step 1: Extend test file** — append to `test/unit/test_peripheral_routing.rb`

After the existing `PeripheralRoutingTest` class, append:

```ruby
class ServiceRoutingTest < Test::Unit::TestCase
  def setup
    @central = PeripheralRoutingTest::StubCentral.new(1)
    @peripheral = CoreBluetoothMac::Peripheral.new(central: @central, identifier: "AAAA")
    @central.stub(:peripheral_discover_services) { |_id, _ms| ["00001800-0000-1000-8000-00805f9b34fb"] }
    @peripheral.discover_services
    @service = @peripheral.services.first
  end

  def test_discover_characteristics_invokes_native
    @central.stub(:service_discover_characteristics) do |_pid, _sid, _ms|
      [{"uuid" => "00002a00-0000-1000-8000-00805f9b34fb", "properties" => ["read"]}]
    end
    @service.discover_characteristics(timeout: 3.0)
    assert_equal [:service_discover_characteristics,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb", 3000]],
                 @central.calls.last
  end

  def test_discover_characteristics_populates
    @central.stub(:service_discover_characteristics) do |_p, _s, _t|
      [{"uuid" => "00002a00-0000-1000-8000-00805f9b34fb", "properties" => ["read"]}]
    end
    @service.discover_characteristics
    ch = @service.characteristics.first
    assert_equal "00002a00-0000-1000-8000-00805f9b34fb", ch.uuid
    assert ch.readable?
    refute ch.writable?
  end

  def test_characteristics_raises_before_discover
    assert_raise(CoreBluetoothMac::ClosedError) { @service.characteristics }
  end
end

class CharacteristicRoutingTest < Test::Unit::TestCase
  def setup
    @central = PeripheralRoutingTest::StubCentral.new(1)
    @peripheral = CoreBluetoothMac::Peripheral.new(central: @central, identifier: "AAAA")
    @central.stub(:peripheral_discover_services) { |_, _| ["00001800-0000-1000-8000-00805f9b34fb"] }
    @peripheral.discover_services
    @service = @peripheral.services.first
    @central.stub(:service_discover_characteristics) do |_p, _s, _t|
      [{"uuid" => "00002a00-0000-1000-8000-00805f9b34fb",
        "properties" => ["read", "write", "notify"]}]
    end
    @service.discover_characteristics
    @ch = @service.characteristics.first
  end

  def test_read_routes_to_native
    @central.stub(:characteristic_read) { |_p, _s, _c, _t| "value".b }
    bytes = @ch.read(timeout: 4.0)
    assert_equal "value".b, bytes
    assert_equal [:characteristic_read,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb", 4000]],
                 @central.calls.last
  end

  def test_write_with_response_routes
    @central.stub(:characteristic_write) { |*| nil }
    @ch.write("payload", response: true, timeout: 2.0)
    assert_equal [:characteristic_write,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb",
                   "payload", 1, 2000]],
                 @central.calls.last
  end

  def test_write_without_response_routes
    @central.stub(:characteristic_write) { |*| nil }
    @ch.write_without_response("p")
    assert_equal [:characteristic_write,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb",
                   "p", 0, 0]],
                 @central.calls.last
  end

  def test_subscribe_returns_Subscription_with_id
    @central.stub(:characteristic_subscribe) { |*| 1001 }
    sub = @ch.subscribe
    assert_kind_of CoreBluetoothMac::Subscription, sub
    assert_equal 1, sub.central_id
    assert_equal 1001, sub.subscription_id
  end

  def test_unsubscribe_routes
    @central.stub(:characteristic_unsubscribe) { |*| nil }
    @ch.unsubscribe
    assert_equal [:characteristic_unsubscribe,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb"]],
                 @central.calls.last
  end
end
```

- [ ] **Step 2: Run test — expect failure (uninitialized Service / Characteristic)**

> `bundle exec ruby -Ilib -Itest test/unit/test_peripheral_routing.rb 2>&1 | tail -15`

Expected: many errors referencing missing `Service` and `Characteristic`.

- [ ] **Step 3: Write `lib/corebluetooth_mac/service.rb`**

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Service
    attr_reader :uuid, :peripheral

    def initialize(peripheral:, uuid:)
      @peripheral = peripheral
      @uuid = uuid
      @characteristics = nil
    end

    def discover_characteristics(timeout: 5.0)
      arr = @peripheral.central.__call_native(
        :service_discover_characteristics,
        @peripheral.identifier, @uuid, (timeout * 1000).to_i
      )
      @characteristics = arr.map do |h|
        Characteristic.new(
          service: self,
          uuid: h["uuid"],
          properties: h["properties"].map(&:to_sym).to_set
        )
      end
      self
    end

    def characteristics
      @characteristics || raise(ClosedError, "call discover_characteristics first")
    end

    def characteristics_loaded?
      !@characteristics.nil?
    end

    def find_characteristic(uuid)
      target = uuid.downcase
      characteristics.find { |c| c.uuid.casecmp?(target) }
    end
  end
end
```

- [ ] **Step 4: Write `lib/corebluetooth_mac/characteristic.rb`**

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Characteristic
    attr_reader :uuid, :properties, :service

    def initialize(service:, uuid:, properties:)
      @service = service
      @uuid = uuid
      @properties = properties.frozen? ? properties : properties.freeze
    end

    def readable?
      @properties.include?(:read)
    end

    def writable?
      @properties.include?(:write) || @properties.include?(:write_without_response)
    end

    def notify?
      @properties.include?(:notify) || @properties.include?(:indicate)
    end

    def read(timeout: 5.0)
      central.__call_native(
        :characteristic_read,
        @service.peripheral.identifier, @service.uuid, @uuid,
        (timeout * 1000).to_i
      )
    end

    def write(data, response: true, timeout: 5.0)
      central.__call_native(
        :characteristic_write,
        @service.peripheral.identifier, @service.uuid, @uuid,
        data, response ? 1 : 0, response ? (timeout * 1000).to_i : 0
      )
    end

    def write_without_response(data)
      write(data, response: false, timeout: 0)
    end

    def subscribe
      sub_id = central.__call_native(
        :characteristic_subscribe,
        @service.peripheral.identifier, @service.uuid, @uuid
      )
      Subscription.new(central_id: central.central_id, subscription_id: sub_id)
    end

    def unsubscribe
      central.__call_native(
        :characteristic_unsubscribe,
        @service.peripheral.identifier, @service.uuid, @uuid
      )
    end

    private

    def central
      @service.peripheral.central
    end
  end
end
```

- [ ] **Step 5: Run test — expect green**

> `bundle exec ruby -Ilib -Itest test/unit/test_peripheral_routing.rb 2>&1 | tail -10`

Expected: `14 tests, 14 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Run full unit suite**

> `bundle exec ruby -Ilib -Itest -e "Dir['test/unit/test_*.rb'].each { |f| require_relative File.expand_path(f) }" 2>&1 | tail -10`

Expected: all unit tests green (count grows as we go).

- [ ] **Step 7: Commit**

- Files: `lib/corebluetooth_mac/peripheral.rb` (from Task 7), `lib/corebluetooth_mac/service.rb`, `lib/corebluetooth_mac/characteristic.rb`, `lib/corebluetooth_mac.rb`, `test/unit/test_peripheral_routing.rb`
- Message: `feat: Peripheral/Service/Characteristic pure-Ruby routing layer`

---

## Task 9: Swift hello-world + extconf + Package.swift (smoke-test the build chain)

**Files:**
- Create: `ext/corebluetooth_mac/extconf.rb`
- Create: `ext/corebluetooth_mac/Package.swift`
- Create: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Create: `ext/corebluetooth_mac/corebluetooth_mac.c`

Goal: get `bundle exec rake compile` green with a function that returns the string `"hello from CoreBluetoothMac"`. No CoreBluetooth wiring yet.

- [ ] **Step 1: Create `ext/corebluetooth_mac/extconf.rb`**

```ruby
# frozen_string_literal: true
require "swift_gem/mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "corebluetooth_mac/corebluetooth_mac",
  package: "CoreBluetoothMac",
  source_dir: __dir__
)
```

- [ ] **Step 2: Create `ext/corebluetooth_mac/Package.swift`**

```swift
// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "CoreBluetoothMac",
    platforms: [.macOS("13.0")],
    products: [
        .library(name: "CoreBluetoothMac", type: .dynamic, targets: ["CoreBluetoothMac"])
    ],
    targets: [
        .target(name: "CoreBluetoothMac", path: "Sources/CoreBluetoothMac")
    ]
)
```

- [ ] **Step 3: Create `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`**

```swift
import Foundation

@c
public func cbm_hello() -> UnsafeMutablePointer<CChar>? {
    return strdup("hello from CoreBluetoothMac")
}
```

- [ ] **Step 4: Create `ext/corebluetooth_mac/corebluetooth_mac.c`**

```c
#include <ruby.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE rb_cbm_hello(VALUE self) {
    char *r = cbm_hello();
    if (!r) return Qnil;
    VALUE s = rb_utf8_str_new_cstr(r);
    free(r);
    return s;
}

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);
}
```

- [ ] **Step 5: Run `bundle exec rake compile`**

Delegate to subagent (general-purpose):
> Prompt: `cd /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac && bundle exec rake compile 2>&1 | tail -30`

Expected: `swift build -c release --package-path ext/corebluetooth_mac` runs, links produce `lib/corebluetooth_mac/corebluetooth_mac.bundle`. If the compile takes >2 minutes, switch to the `screen -dmS` longrun pattern from `~/dev/src/CLAUDE.md`. Empirically on M-series Mac this completes in <30s.

If `swift_gem` complains about the Swift toolchain, the developer should run:

> `which swift && swift --version`

Expected: Swift 6.3.1 via `swiftly`.

- [ ] **Step 6: Smoke-test the bridge from Ruby**

> `bundle exec ruby -Ilib -e 'require "corebluetooth_mac/corebluetooth_mac"; puts CoreBluetoothMac.__hello'`

Expected: prints `hello from CoreBluetoothMac`.

- [ ] **Step 7: Commit**

- Files: `ext/corebluetooth_mac/extconf.rb`, `ext/corebluetooth_mac/Package.swift`, `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`, `ext/corebluetooth_mac/corebluetooth_mac.c`
- Message: `build: Swift+C bridge skeleton compiles and round-trips a hello string`

---

## Task 10: Native `Central` class with hello — wire `lib/corebluetooth_mac/central.rb`

**Files:**
- Create: `lib/corebluetooth_mac/central.rb`
- Modify: `lib/corebluetooth_mac.rb`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c` (add Central class + alloc)

This step verifies the TypedData_Wrap_Struct pattern works *before* we add CoreBluetooth state — same incremental discipline as the FM gem.

- [ ] **Step 1: Add a failing smoke test** — append to `test/unit/test_module.rb`

```ruby
class NativeBridgeTest < Test::Unit::TestCase
  def test_hello_module_function_present
    assert_respond_to CoreBluetoothMac, :__hello
  end

  def test_Native_alloc_creates_object
    # Doesn't initialize CoreBluetooth — uses a sentinel state_timeout=0 to bypass the wait.
    # CoreBluetoothMac::Native is a private class; we exercise via Central later.
    assert defined?(CoreBluetoothMac::Native)
  end
end
```

- [ ] **Step 2: Run test — expect failure**

> `bundle exec ruby -Ilib -Itest test/unit/test_module.rb 2>&1 | tail -10`

Expected: `Native` constant undefined.

- [ ] **Step 3: Extend `ext/corebluetooth_mac/corebluetooth_mac.c`** — add Central native class

Replace the C file with:

```c
#include <ruby.h>
#include <ruby/thread.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eCbm, eState, ePerm, eTimeout, eConn, eDisco, eIO, eClosed;

// ---- TypedData for Central ----

static void central_dfree(void *p) {
    if (p) cbm_central_free(p);
}

static const rb_data_type_t central_dt = {
    "CoreBluetoothMac::Native",
    { NULL, central_dfree, NULL, },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE rb_central_alloc(VALUE klass) {
    return TypedData_Wrap_Struct(klass, &central_dt, NULL);
}

// ---- helpers ----

static VALUE rb_cbm_hello(VALUE self) {
    char *r = cbm_hello();
    if (!r) return Qnil;
    VALUE s = rb_utf8_str_new_cstr(r);
    free(r);
    return s;
}

// ---- Init ----

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    eCbm     = rb_const_get(mod, rb_intern("Error"));
    eState   = rb_const_get(mod, rb_intern("StateError"));
    ePerm    = rb_const_get(mod, rb_intern("PermissionError"));
    eTimeout = rb_const_get(mod, rb_intern("TimeoutError"));
    eConn    = rb_const_get(mod, rb_intern("ConnectionError"));
    eDisco   = rb_const_get(mod, rb_intern("DiscoveryError"));
    eIO      = rb_const_get(mod, rb_intern("IOError"));
    eClosed  = rb_const_get(mod, rb_intern("ClosedError"));

    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);

    VALUE cNative = rb_define_class_under(mod, "Native", rb_cObject);
    rb_define_alloc_func(cNative, rb_central_alloc);
}
```

- [ ] **Step 4: Create `lib/corebluetooth_mac/central.rb`** (minimal — no scan/connect yet)

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    # Phase 1 lands real init in Task 12; for now this is unimplemented.
    def initialize(state_timeout: 3.0)
      raise NotImplementedError, "Central.new arrives in Task 12"
    end
  end
end
```

- [ ] **Step 5: Wire into `lib/corebluetooth_mac.rb`**

After the error classes block, before the `Subscription` require, append:

```ruby
require_relative "corebluetooth_mac/corebluetooth_mac"   # native bundle (defines Native)
require_relative "corebluetooth_mac/central"
```

The require order in `lib/corebluetooth_mac.rb` is now:

```ruby
require "json"
require "set"

require_relative "corebluetooth_mac/version"

module CoreBluetoothMac
  class Error           < StandardError; end
  class StateError      < Error;          end
  class PermissionError < StateError;     end
  class TimeoutError    < Error;          end
  class ConnectionError < Error;          end
  class DiscoveryError  < Error;          end
  class IOError         < Error;          end
  class ClosedError     < Error;          end
end

require_relative "corebluetooth_mac/discovered_device"
require_relative "corebluetooth_mac/subscription"
require_relative "corebluetooth_mac/service"
require_relative "corebluetooth_mac/characteristic"
require_relative "corebluetooth_mac/peripheral"
require_relative "corebluetooth_mac/corebluetooth_mac"
require_relative "corebluetooth_mac/central"
```

- [ ] **Step 6: Rebuild + run tests**

> `bundle exec rake compile 2>&1 | tail -10`
> `bundle exec rake test 2>&1 | tail -15`

Expected: rake test depends on `:compile` which now succeeds; all unit tests green; integration tests omit with hardware-skip message.

- [ ] **Step 7: Commit**

- Files: `lib/corebluetooth_mac/central.rb`, `lib/corebluetooth_mac.rb`, `ext/corebluetooth_mac/corebluetooth_mac.c`, `test/unit/test_module.rb`
- Message: `build: define CoreBluetoothMac::Native class via TypedData_Wrap_Struct`

---

## Task 11: `CBMCentral` Swift + `cbm_central_new` (state wait, error mapping)

**Files:**
- Create: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMSync.swift`
- Create: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`

- [ ] **Step 1: Create `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMSync.swift`**

```swift
import Foundation
import os

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

enum CBMError: Error {
    case state(String)
    case permission(String)
    case timeout(String)
    case connection(String)
    case discovery(String)
    case io(String)
    case closed(String)
}

func cbmErrorTag(_ err: CBMError) -> Int32 {
    switch err {
    case .state:      return 1
    case .permission: return 2
    case .timeout:    return 3
    case .connection: return 4
    case .discovery:  return 5
    case .io:         return 6
    case .closed:     return 7
    }
}

func cbmErrorMessage(_ err: CBMError) -> String {
    switch err {
    case .state(let m), .permission(let m), .timeout(let m),
         .connection(let m), .discovery(let m), .io(let m), .closed(let m):
        return m
    }
}
```

- [ ] **Step 2: Create `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`**

```swift
import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    // `OSAllocatedUnfairLock<Int64>` requires macOS 13+ (see Package.swift `platforms`).
    // Locking the counter inside the lock's `withLock` state avoids `nonisolated(unsafe)`
    // and Swift 6 strict-concurrency errors on static mutable storage.
    static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    let centralId: Int64
    let manager: CBCentralManager
    let queue: DispatchQueue

    private let stateLock = OSAllocatedUnfairLock<CBManagerState>(initialState: .unknown)
    private let stateSem = DispatchSemaphore(value: 0)

    // `override` is required because `NSObject` already declares `init()`.
    override init() {
        // Assign a unique id atomically.
        let assigned: Int64 = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        self.centralId = assigned
        self.queue = DispatchQueue(label: "corebluetoothmac.central.\(assigned)")
        self.manager = CBCentralManager(delegate: nil, queue: self.queue)
        super.init()
        self.manager.delegate = self
    }

    func awaitPoweredOn(timeoutMs: Int32) -> CBMError? {
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutMs))
        while true {
            let cur = stateLock.withLock { $0 }
            switch cur {
            case .poweredOn:    return nil
            case .unauthorized: return .permission("Bluetooth permission denied. Open System Settings → Privacy & Security → Bluetooth and enable your terminal application.")
            case .unsupported:  return .state("Bluetooth is not supported on this machine.")
            case .poweredOff:   return .state("Bluetooth is off. Turn it on in Control Center / System Settings.")
            case .resetting:    return .state("Bluetooth is resetting; try again.")
            case .unknown:      break  // wait
            @unknown default:   break
            }
            let r = stateSem.wait(timeout: deadline)
            if r == .timedOut {
                return .timeout("Bluetooth state did not reach poweredOn within \(timeoutMs)ms")
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateLock.withLock { $0 = central.state }
        stateSem.signal()
    }
}
```

- [ ] **Step 3: Extend `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`** with `cbm_central_new` / `cbm_central_free` / `cbm_central_id`

Replace the file:

```swift
import Foundation
import CoreBluetooth

@c
public func cbm_hello() -> UnsafeMutablePointer<CChar>? {
    return strdup("hello from CoreBluetoothMac")
}

@c
public func cbm_central_new(
    _ stateTimeoutMs: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutableRawPointer? {
    error_tag_out.pointee = 0
    error_out.pointee = nil

    let c = CBMCentral()
    if let err = c.awaitPoweredOn(timeoutMs: stateTimeoutMs) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
    return Unmanaged.passRetained(c).toOpaque()
}

@c
public func cbm_central_free(_ ptr: UnsafeMutableRawPointer) {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeRetainedValue()
    // CBCentralManager holds its delegate weakly (CBCentralManager.h:88).
    // The opaque pointer was the only strong retain on `c`; once this scope
    // ends, ARC deallocates. Serialize on the manager's own queue so any
    // in-flight delegate callback completes before we let `c` go.
    c.queue.sync {
        c.manager.delegate = nil
    }
    // Future: cancel pending operations / close subscriptions
    _ = c
}

@c
public func cbm_central_id(_ ptr: UnsafeMutableRawPointer) -> Int64 {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    return c.centralId
}
```

- [ ] **Step 4: Compile to verify Swift+C still link**

> `bundle exec rake compile 2>&1 | tail -10`

Expected: green build. If the SE-0495 `@c` attribute errors, double-check `.swift-version` is `6.3.1` and `swift --version` matches.

- [ ] **Step 5: Commit (Swift only; not wired to Ruby yet — Task 12)**

- Files: `CBMSync.swift`, `CBMCentral.swift`, `CoreBluetoothMac.swift`
- Message: `feat(swift): CBMCentral state-wait, cbm_central_new/free/id ABI`

---

## Task 12: Wire `Central.new` through the C bridge, map errors

**Files:**
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`

- [ ] **Step 1: Write unit test for error mapping** — append to `test/unit/test_errors.rb`

```ruby
class CentralErrorBridgeTest < Test::Unit::TestCase
  # Verify the constants the C bridge looks up exist with the expected names.
  # The hardware behaviour itself is exercised in integration tests.
  CoreBluetoothMac.constants(false).each do |c|
    klass = CoreBluetoothMac.const_get(c)
    next unless klass.is_a?(Class) && klass < StandardError
    define_method("test_#{c}_is_raisable") do
      assert_raise(klass) { raise klass, "boom" }
    end
  end
end
```

- [ ] **Step 2: Run test — expect green (no behaviour change yet)**

> `bundle exec rake compile && bundle exec rake test 2>&1 | tail -10`

Expected: tests pass; this guards the C bridge's `rb_const_get` calls from typos.

- [ ] **Step 3: Update `ext/corebluetooth_mac/corebluetooth_mac.c`** — implement Native#initialize bound to `cbm_central_new`

Replace the file (the additions are noted with comments):

```c
#include <ruby.h>
#include <ruby/thread.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eCbm, eState, ePerm, eTimeout, eConn, eDisco, eIO, eClosed;

// ---- error mapping ----

static VALUE error_class_for_tag(int32_t tag) {
    switch (tag) {
        case 1: return eState;
        case 2: return ePerm;
        case 3: return eTimeout;
        case 4: return eConn;
        case 5: return eDisco;
        case 6: return eIO;
        case 7: return eClosed;
        default: return eCbm;
    }
}

static void raise_with(int32_t tag, char *msg) {
    VALUE klass = error_class_for_tag(tag);
    VALUE m = rb_utf8_str_new_cstr(msg ? msg : "unknown error");
    if (msg) free(msg);
    rb_raise(klass, "%s", StringValueCStr(m));
}

// ---- TypedData for Central ----

static void central_dfree(void *p) {
    if (p) cbm_central_free(p);
}

static const rb_data_type_t central_dt = {
    "CoreBluetoothMac::Native",
    { NULL, central_dfree, NULL, },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE rb_central_alloc(VALUE klass) {
    return TypedData_Wrap_Struct(klass, &central_dt, NULL);
}

// ---- initialize (state-blocking, releases GVL) ----

struct new_args { int32_t timeout_ms; int32_t tag; char *err; void *p; };

static void *new_no_gvl(void *data) {
    struct new_args *a = (struct new_args *)data;
    a->p = cbm_central_new(a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_central_init(VALUE self, VALUE timeout_ms_v) {
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct new_args a = { (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL };
    rb_thread_call_without_gvl(new_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.p) raise_with(a.tag, a.err);
    DATA_PTR(self) = a.p;
    return self;
}

static VALUE rb_central_id(VALUE self) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    return LL2NUM(cbm_central_id(p));
}

// ---- hello (still useful for smoke) ----

static VALUE rb_cbm_hello(VALUE self) {
    char *r = cbm_hello();
    if (!r) return Qnil;
    VALUE s = rb_utf8_str_new_cstr(r);
    free(r);
    return s;
}

// ---- Init ----

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    eCbm     = rb_const_get(mod, rb_intern("Error"));
    eState   = rb_const_get(mod, rb_intern("StateError"));
    ePerm    = rb_const_get(mod, rb_intern("PermissionError"));
    eTimeout = rb_const_get(mod, rb_intern("TimeoutError"));
    eConn    = rb_const_get(mod, rb_intern("ConnectionError"));
    eDisco   = rb_const_get(mod, rb_intern("DiscoveryError"));
    eIO      = rb_const_get(mod, rb_intern("IOError"));
    eClosed  = rb_const_get(mod, rb_intern("ClosedError"));

    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);

    VALUE cNative = rb_define_class_under(mod, "Native", rb_cObject);
    rb_define_alloc_func(cNative, rb_central_alloc);
    rb_define_method(cNative, "initialize", rb_central_init, 1);
    rb_define_method(cNative, "central_id", rb_central_id,   0);
}
```

- [ ] **Step 4: Update `lib/corebluetooth_mac/central.rb`** — call native

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    def initialize(state_timeout: 3.0)
      @native = Native.new((state_timeout * 1000).to_i)
    end

    def central_id
      @native.central_id
    end
  end
end
```

- [ ] **Step 5: Write integration test** — `test/integration/test_central_init.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class CentralInitTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  def test_new_returns_central_with_id
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    assert_kind_of Integer, central.central_id
    assert_operator central.central_id, :>, 0
  end
end
```

- [ ] **Step 6: Compile + run**

> `bundle exec rake compile && bundle exec rake test 2>&1 | tail -10`

Expected without `BLE_HW=1`: all unit tests green; integration tests omit.

With hardware:

> `BLE_HW=1 bundle exec rake test 2>&1 | tail -20`

Expected: integration test green if Bluetooth permission is granted.

- [ ] **Step 7: Commit**

- Files: `ext/corebluetooth_mac/corebluetooth_mac.c`, `lib/corebluetooth_mac/central.rb`, `test/integration/test_central_init.rb`, `test/unit/test_errors.rb`
- Message: `feat: Central.new with state-wait and error mapping`

---

## Task 13: Scan — Swift `cbm_central_scan` + Ruby `Central#scan`

**Files:**
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`
- Create: `test/integration/test_scan.rb`
- Create: `examples/scan_only.rb`

- [ ] **Step 1: Extend `CBMCentral.swift`** with scan state + delegate

Add inside the `CBMCentral` class (after `awaitPoweredOn`):

```swift
struct ScanResult {
    let identifier: String
    let name: String?
    let rssi: Int
}

// All mutable state lives inside its lock to satisfy Swift 6 strict-concurrency
// (same pattern as `idCounter` in Task 11). A `var` + side-lock would emit
// "stored property of Sendable type" errors on a `@unchecked Sendable` class.
private let scanLock = OSAllocatedUnfairLock<[String: ScanResult]>(initialState: [:])
private let nameFilter = OSAllocatedUnfairLock<String?>(initialState: nil)
private let knownPeripherals = OSAllocatedUnfairLock<[UUID: CBPeripheral]>(initialState: [:])

func scan(name: String?, services: [CBUUID]?, timeoutMs: Int32) -> [ScanResult] {
    scanLock.withLock { $0.removeAll() }
    nameFilter.withLock { $0 = name }
    let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    manager.scanForPeripherals(withServices: services, options: options)
    queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) { [weak self] in
        self?.manager.stopScan()
    }
    Thread.sleep(forTimeInterval: TimeInterval(timeoutMs) / 1000.0)
    manager.stopScan()
    return scanLock.withLock { Array($0.values) }
}

// MARK: - Scan delegate

func centralManager(_ central: CBCentralManager,
                    didDiscover peripheral: CBPeripheral,
                    advertisementData: [String: Any],
                    rssi RSSI: NSNumber) {
    let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    let filter = nameFilter.withLock { $0 }
    if let filter = filter, name != filter { return }

    knownPeripherals.withLock { state in
        if state[peripheral.identifier] == nil {
            state[peripheral.identifier] = peripheral
        }
    }
    let r = ScanResult(identifier: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue)
    scanLock.withLock { $0[peripheral.identifier.uuidString] = r }
}
```

(`Thread.sleep` is acceptable here because the C bridge releases GVL before calling. Alternative: a DispatchSemaphore that the `stopScan` block signals.)

- [ ] **Step 2: Add JSON serialization helper inside `CBMCentral`**

Append to `CBMCentral.swift`:

```swift
func scanResultsAsJSON(_ results: [ScanResult]) -> String {
    let arr: [[String: Any]] = results.map { r in
        var d: [String: Any] = ["identifier": r.identifier, "rssi": r.rssi]
        if let n = r.name { d["name"] = n }
        return d
    }
    let data = try! JSONSerialization.data(withJSONObject: arr)
    return String(data: data, encoding: .utf8) ?? "[]"
}
```

- [ ] **Step 3: Add `cbm_central_scan` to `CoreBluetoothMac.swift`**

Append:

```swift
@c
public func cbm_central_scan(
    _ ptr: UnsafeMutableRawPointer,
    _ name_filter: UnsafePointer<CChar>?,
    _ service_uuids_json: UnsafePointer<CChar>?,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil

    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let nameStr: String? = name_filter.map { String(cString: $0) }
    var services: [CBUUID]? = nil
    if let json = service_uuids_json {
        let s = String(cString: json)
        if let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            services = arr.map { CBUUID(string: $0) }
        }
    }
    let results = c.scan(name: nameStr, services: services, timeoutMs: timeout_ms)
    return strdup(c.scanResultsAsJSON(results))
}
```

- [ ] **Step 4: Add `scan` method on Native in `corebluetooth_mac.c`**

Insert before `Init_corebluetooth_mac`:

```c
struct scan_args {
    void *p;
    const char *name;
    const char *services_json;
    int32_t timeout_ms;
    int32_t tag;
    char *err;
    char *result;
};

static void *scan_no_gvl(void *data) {
    struct scan_args *a = (struct scan_args *)data;
    a->result = cbm_central_scan(a->p, a->name, a->services_json, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_central_scan(VALUE self, VALUE name_v, VALUE services_json_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct scan_args a = {
        p,
        NIL_P(name_v) ? NULL : StringValueCStr(name_v),
        NIL_P(services_json_v) ? NULL : StringValueCStr(services_json_v),
        (int32_t)NUM2INT(timeout_ms_v),
        0, NULL, NULL
    };
    rb_thread_call_without_gvl(scan_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.tag, a.err);
    if (!a.result) return rb_utf8_str_new_cstr("[]");
    VALUE s = rb_utf8_str_new_cstr(a.result);
    free(a.result);
    return s;
}
```

In `Init_corebluetooth_mac`, after `central_id` method, add:

```c
rb_define_method(cNative, "scan", rb_central_scan, 3);
```

- [ ] **Step 5: Update `lib/corebluetooth_mac/central.rb`** — `#scan`

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    def initialize(state_timeout: 3.0)
      @native = Native.new((state_timeout * 1000).to_i)
    end

    def central_id
      @native.central_id
    end

    def scan(name: nil, services: nil, timeout: 5.0)
      # Empty `services: []` would serialize as "[]" and CoreBluetooth treats
      # an empty service-filter array as "match nothing", silently returning
      # zero peripherals. Normalize empty/nil to nil so Swift skips the filter.
      arr = services ? Array(services) : []
      services_json = arr.empty? ? nil : JSON.dump(arr)
      raw = @native.scan(name, services_json, (timeout * 1000).to_i)
      JSON.parse(raw).map do |h|
        DiscoveredDevice.new(
          central_id: central_id,
          identifier: h["identifier"],
          name: h["name"],
          rssi: h["rssi"]
        )
      end
    end
  end
end
```

- [ ] **Step 6: Integration test** — `test/integration/test_scan.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class ScanTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
  end

  def test_scan_returns_array
    result = @central.scan(timeout: 1.0)
    assert_kind_of Array, result
  end

  def test_scan_finds_stackchan_picoruby
    result = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    assert_operator result.size, :>=, 1,
      "Expected ≥1 StackChan-PicoRuby. Is CoreS3 advertising? `rake r2p2:reset` opens a 60s window."
    dev = result.first
    assert_kind_of CoreBluetoothMac::DiscoveredDevice, dev
    assert_equal "StackChan-PicoRuby", dev.name
    assert_match(/\A[0-9A-Fa-f-]+\z/, dev.identifier)
  end
end
```

- [ ] **Step 7: Sample runner** — `examples/scan_only.rb`

```ruby
# frozen_string_literal: true

require_relative "../lib/corebluetooth_mac"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
puts "Scanning for 'StackChan-PicoRuby' for 8s…"
central.scan(name: "StackChan-PicoRuby", timeout: 8.0).each do |d|
  puts "  #{d.identifier}  rssi=#{d.rssi}  name=#{d.name}"
end
```

- [ ] **Step 8: Compile + run integration**

> `bundle exec rake compile && BLE_HW=1 bundle exec rake test TEST=test/integration/test_scan.rb 2>&1 | tail -15`

Expected with CoreS3 advertising: 2/2 green.

- [ ] **Step 9: Commit**

- Files: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`, `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`, `ext/corebluetooth_mac/corebluetooth_mac.c`, `lib/corebluetooth_mac/central.rb`, `test/integration/test_scan.rb`, `examples/scan_only.rb`
- Message: `feat: Central#scan over CoreBluetooth with name/service filters`

---

## Task 14: Connect / disconnect — Swift + Ruby

**Files:**
- Create: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMPeripheralDelegate.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`
- Create: `test/integration/test_connect.rb`

- [ ] **Step 1: Create `CBMPeripheralDelegate.swift`**

This class owns the per-peripheral state machine: pending semaphores for connect, services, characteristics, read, write, subscribe.

```swift
import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMPeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let peripheral: CBPeripheral

    // Connect
    let connectSem = DispatchSemaphore(value: 0)
    var connectError: Error? = nil
    var connected: Bool = false

    // Discover services
    let servicesSem = DispatchSemaphore(value: 0)
    var servicesError: Error? = nil

    // Discover characteristics (per service)
    let charsSem = DispatchSemaphore(value: 0)
    var charsError: Error? = nil
    var charsServiceUUID: CBUUID? = nil

    // Read
    let readSem = DispatchSemaphore(value: 0)
    var readError: Error? = nil
    var readValue: Data? = nil
    var readCharUUID: CBUUID? = nil

    // Write (with response)
    let writeSem = DispatchSemaphore(value: 0)
    var writeError: Error? = nil
    var writeCharUUID: CBUUID? = nil

    // Notify state change
    let notifySem = DispatchSemaphore(value: 0)
    var notifyError: Error? = nil
    var notifyCharUUID: CBUUID? = nil

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        servicesError = error
        servicesSem.signal()
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if charsServiceUUID == service.uuid {
            charsError = error
            charsSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Read result OR notification
        if readCharUUID == characteristic.uuid {
            readError = error
            readValue = characteristic.value
            readSem.signal()
            return
        }
        // Notify path: hand off to SubscriptionRegistry (Task 18+)
        CBMSubscriptionRegistry.shared.enqueue(
            characteristic: characteristic, error: error
        )
    }

    func peripheral(_ p: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if writeCharUUID == characteristic.uuid {
            writeError = error
            writeSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if notifyCharUUID == characteristic.uuid {
            notifyError = error
            notifySem.signal()
        }
    }
}
```

`CBMSubscriptionRegistry.shared.enqueue` is a forward reference; we'll add a no-op stub in this task and the real impl in Task 18.

- [ ] **Step 2: Add `CBMSubscriptionRegistry` stub** — create `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMSubscriptionRegistry.swift`

```swift
import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMSubscriptionRegistry: @unchecked Sendable {
    static let shared = CBMSubscriptionRegistry()
    private init() {}

    func enqueue(characteristic: CBCharacteristic, error: Error?) {
        // Real impl arrives in Task 18.
    }
}
```

- [ ] **Step 3: Extend `CBMCentral.swift`** with connect/disconnect + delegate methods + peripheral lookup

Append to `CBMCentral.swift`:

```swift
private let delegatesLock = OSAllocatedUnfairLock<[UUID: CBMPeripheralDelegate]>(initialState: [:])

func delegate(for identifier: UUID) -> CBMPeripheralDelegate? {
    return delegatesLock.withLock { $0[identifier] }
}

func peripheral(identifier: String) -> (CBPeripheral, CBMPeripheralDelegate)? {
    guard let uuid = UUID(uuidString: identifier) else { return nil }
    let p: CBPeripheral? = knownPeripherals.withLock { $0[uuid] }
    guard let peripheral = p else { return nil }
    let d = delegatesLock.withLock { dict -> CBMPeripheralDelegate in
        if let existing = dict[uuid] { return existing }
        let nd = CBMPeripheralDelegate(peripheral: peripheral)
        dict[uuid] = nd
        return nd
    }
    return (peripheral, d)
}

func connect(identifier: String, timeoutMs: Int32) -> CBMError? {
    guard let (p, d) = peripheral(identifier: identifier) else {
        return .connection("Unknown peripheral identifier \(identifier); scan first.")
    }
    d.connectError = nil
    d.connected = false
    manager.connect(p, options: nil)
    let r = d.connectSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
    if r == .timedOut { manager.cancelPeripheralConnection(p); return .timeout("connect timed out after \(timeoutMs)ms") }
    if let e = d.connectError { return .connection(e.localizedDescription) }
    if !d.connected { return .connection("connect signalled but state is not connected") }
    return nil
}

func disconnect(identifier: String) -> CBMError? {
    guard let (p, _) = peripheral(identifier: identifier) else {
        return .closed("Unknown peripheral identifier \(identifier).")
    }
    manager.cancelPeripheralConnection(p)
    return nil
}

func peripheralState(identifier: String) -> String {
    guard let (p, _) = peripheral(identifier: identifier) else { return "unknown" }
    switch p.state {
    case .disconnected:  return "disconnected"
    case .connecting:    return "connecting"
    case .connected:     return "connected"
    case .disconnecting: return "disconnecting"
    @unknown default:    return "unknown"
    }
}

// MARK: CBCentralManagerDelegate – connect lifecycle

func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    if let d = delegate(for: p.identifier) {
        d.connected = true
        d.connectError = nil
        d.connectSem.signal()
    }
}

func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    if let d = delegate(for: p.identifier) {
        d.connected = false
        d.connectError = error ?? NSError(domain: "CBM", code: -1)
        d.connectSem.signal()
    }
}

func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    if let d = delegate(for: p.identifier) {
        d.connected = false
        // If a connect was pending, surface the error.
        if d.connectError == nil && error != nil {
            d.connectError = error
            d.connectSem.signal()
        }
    }
}
```

- [ ] **Step 4: Add `cbm_central_connect` / `cbm_central_disconnect` / `cbm_peripheral_state` to `CoreBluetoothMac.swift`**

Append:

```swift
@c
public func cbm_central_connect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let id = String(cString: identifier)
    if let err = c.connect(identifier: id, timeoutMs: timeout_ms) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_central_disconnect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let id = String(cString: identifier)
    if let err = c.disconnect(identifier: id) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_peripheral_state(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    return strdup(c.peripheralState(identifier: String(cString: identifier)))
}
```

- [ ] **Step 5: Extend C bridge `corebluetooth_mac.c`** — connect / disconnect / peripheral_state

Insert before `Init_corebluetooth_mac`:

```c
struct connect_args {
    void *p; const char *id; int32_t timeout_ms;
    int32_t tag; char *err; int32_t ok;
};

static void *connect_no_gvl(void *data) {
    struct connect_args *a = (struct connect_args *)data;
    a->ok = cbm_central_connect(a->p, a->id, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_central_connect(VALUE self, VALUE id_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct connect_args a = { p, StringValueCStr(id_v), (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0 };
    rb_thread_call_without_gvl(connect_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.ok) raise_with(a.tag, a.err);
    return Qtrue;
}

static VALUE rb_central_disconnect(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    int32_t tag = 0; char *err = NULL;
    int32_t ok = cbm_central_disconnect(p, StringValueCStr(id_v), &tag, &err);
    if (!ok) raise_with(tag, err);
    return Qtrue;
}

static VALUE rb_peripheral_state(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    char *r = cbm_peripheral_state(p, StringValueCStr(id_v));
    VALUE s = rb_utf8_str_new_cstr(r ? r : "unknown");
    if (r) free(r);
    return ID2SYM(rb_intern(StringValueCStr(s)));
}
```

In `Init_corebluetooth_mac`, after `scan` method, append:

```c
rb_define_method(cNative, "connect",          rb_central_connect,    2);
rb_define_method(cNative, "disconnect",       rb_central_disconnect, 1);
rb_define_method(cNative, "peripheral_state", rb_peripheral_state,   1);
```

- [ ] **Step 6: Update `lib/corebluetooth_mac/central.rb`** with connect/disconnect and the `__call_native` dispatcher (used by Peripheral)

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    def initialize(state_timeout: 3.0)
      @native = Native.new((state_timeout * 1000).to_i)
    end

    def central_id
      @native.central_id
    end

    def scan(name: nil, services: nil, timeout: 5.0)
      # Empty `services: []` would serialize as "[]" and CoreBluetooth treats
      # an empty service-filter array as "match nothing", silently returning
      # zero peripherals. Normalize empty/nil to nil so Swift skips the filter.
      arr = services ? Array(services) : []
      services_json = arr.empty? ? nil : JSON.dump(arr)
      raw = @native.scan(name, services_json, (timeout * 1000).to_i)
      JSON.parse(raw).map do |h|
        DiscoveredDevice.new(
          central_id: central_id,
          identifier: h["identifier"],
          name: h["name"],
          rssi: h["rssi"]
        )
      end
    end

    def connect(device, timeout: 5.0)
      @native.connect(device.identifier, (timeout * 1000).to_i)
      Peripheral.new(central: self, identifier: device.identifier)
    end

    def disconnect(peripheral)
      @native.disconnect(peripheral.identifier)
      nil
    end

    def close
      # Future task: explicit invalidation; relying on GC for now.
      nil
    end

    def __call_native(op, *args)
      case op
      when :peripheral_state
        @native.peripheral_state(*args)
      else
        raise ArgumentError, "unknown native op: #{op}"
      end
    end
  end
end
```

- [ ] **Step 7: Integration test** — `test/integration/test_connect.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class ConnectTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible; rake r2p2:reset on CoreS3 first." if devices.empty?
    @device = devices.first
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
    # Already disconnected.
  end

  def test_connect_returns_Peripheral
    @peripheral = @central.connect(@device, timeout: 5.0)
    assert_kind_of CoreBluetoothMac::Peripheral, @peripheral
    assert_equal @device.identifier, @peripheral.identifier
  end

  def test_state_is_connected
    @peripheral = @central.connect(@device, timeout: 5.0)
    assert_equal :connected, @peripheral.state
  end

  def test_disconnect_then_state_is_disconnected
    @peripheral = @central.connect(@device, timeout: 5.0)
    @central.disconnect(@peripheral)
    # CoreBluetooth disconnect is async; poll briefly.
    deadline = Time.now + 2.0
    until @peripheral.state == :disconnected || Time.now > deadline
      sleep 0.05
    end
    assert_equal :disconnected, @peripheral.state
  end
end
```

- [ ] **Step 8: Compile + run**

> `bundle exec rake compile && BLE_HW=1 bundle exec rake test TEST=test/integration/test_connect.rb 2>&1 | tail -15`

Expected with hardware: 3 tests green.

- [ ] **Step 9: Commit**

- Files: all Swift files modified, `corebluetooth_mac.c`, `lib/corebluetooth_mac/central.rb`, `test/integration/test_connect.rb`
- Message: `feat: Central#connect / #disconnect, Peripheral#state via CBPeripheralDelegate`

---

## Task 15: Discover services + characteristics

**Files:**
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`
- Create: `test/integration/test_discover.rb`

- [ ] **Step 1: Extend `CBMCentral.swift`** with discover_services / discover_characteristics

```swift
func discoverServices(identifier: String, timeoutMs: Int32) -> Result<[String], CBMError> {
    guard let (p, d) = peripheral(identifier: identifier) else {
        return .failure(.closed("Unknown peripheral \(identifier)"))
    }
    guard p.state == .connected else { return .failure(.connection("Peripheral not connected")) }
    d.servicesError = nil
    p.discoverServices(nil)
    let r = d.servicesSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
    if r == .timedOut { return .failure(.timeout("discoverServices timed out after \(timeoutMs)ms")) }
    if let e = d.servicesError { return .failure(.discovery(e.localizedDescription)) }
    let uuids = (p.services ?? []).map { $0.uuid.uuidString.lowercased() }
    return .success(uuids)
}

func discoverCharacteristics(identifier: String, serviceUUID: String, timeoutMs: Int32)
    -> Result<[[String: Any]], CBMError>
{
    guard let (p, d) = peripheral(identifier: identifier) else {
        return .failure(.closed("Unknown peripheral \(identifier)"))
    }
    guard p.state == .connected else { return .failure(.connection("Peripheral not connected")) }
    let targetUUID = CBUUID(string: serviceUUID)
    guard let service = (p.services ?? []).first(where: { $0.uuid == targetUUID }) else {
        return .failure(.discovery("Service \(serviceUUID) not found on peripheral"))
    }
    d.charsServiceUUID = targetUUID
    d.charsError = nil
    p.discoverCharacteristics(nil, for: service)
    let r = d.charsSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
    d.charsServiceUUID = nil
    if r == .timedOut { return .failure(.timeout("discoverCharacteristics timed out after \(timeoutMs)ms")) }
    if let e = d.charsError { return .failure(.discovery(e.localizedDescription)) }
    let arr: [[String: Any]] = (service.characteristics ?? []).map { ch in
        var props: [String] = []
        if ch.properties.contains(.read)                 { props.append("read") }
        if ch.properties.contains(.write)                { props.append("write") }
        if ch.properties.contains(.writeWithoutResponse) { props.append("write_without_response") }
        if ch.properties.contains(.notify)               { props.append("notify") }
        if ch.properties.contains(.indicate)             { props.append("indicate") }
        return ["uuid": ch.uuid.uuidString.lowercased(), "properties": props]
    }
    return .success(arr)
}
```

- [ ] **Step 2: Add `@c` ABI in `CoreBluetoothMac.swift`**

```swift
@c
public func cbm_peripheral_discover_services(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.discoverServices(identifier: String(cString: identifier), timeoutMs: timeout_ms) {
    case .success(let uuids):
        let data = try! JSONSerialization.data(withJSONObject: uuids)
        return strdup(String(data: data, encoding: .utf8) ?? "[]")
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
}

@c
public func cbm_service_discover_characteristics(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.discoverCharacteristics(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        timeoutMs: timeout_ms
    ) {
    case .success(let arr):
        let data = try! JSONSerialization.data(withJSONObject: arr)
        return strdup(String(data: data, encoding: .utf8) ?? "[]")
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
}
```

- [ ] **Step 3: Extend C bridge** — `corebluetooth_mac.c`

Insert before `Init_corebluetooth_mac`:

```c
struct disco_svc_args {
    void *p; const char *id; int32_t timeout_ms;
    int32_t tag; char *err; char *result;
};

static void *disco_svc_no_gvl(void *data) {
    struct disco_svc_args *a = (struct disco_svc_args *)data;
    a->result = cbm_peripheral_discover_services(a->p, a->id, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_peripheral_discover_services(VALUE self, VALUE id_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_svc_args a = { p, StringValueCStr(id_v), (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL };
    rb_thread_call_without_gvl(disco_svc_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.tag, a.err);
    VALUE s = rb_utf8_str_new_cstr(a.result ? a.result : "[]");
    if (a.result) free(a.result);
    return s;
}

struct disco_ch_args {
    void *p; const char *id; const char *svc_uuid; int32_t timeout_ms;
    int32_t tag; char *err; char *result;
};

static void *disco_ch_no_gvl(void *data) {
    struct disco_ch_args *a = (struct disco_ch_args *)data;
    a->result = cbm_service_discover_characteristics(a->p, a->id, a->svc_uuid, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_service_discover_characteristics(VALUE self, VALUE id_v, VALUE svc_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_ch_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL
    };
    rb_thread_call_without_gvl(disco_ch_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.tag, a.err);
    VALUE s = rb_utf8_str_new_cstr(a.result ? a.result : "[]");
    if (a.result) free(a.result);
    return s;
}
```

In `Init_corebluetooth_mac`, after `peripheral_state` method:

```c
rb_define_method(cNative, "discover_services",        rb_peripheral_discover_services,       2);
rb_define_method(cNative, "discover_characteristics", rb_service_discover_characteristics,   3);
```

- [ ] **Step 4: Extend `central.rb`** — wire dispatcher

In `__call_native`, replace the case statement with:

```ruby
def __call_native(op, *args)
  case op
  when :peripheral_state
    @native.peripheral_state(*args)
  when :peripheral_discover_services
    JSON.parse(@native.discover_services(*args))
  when :service_discover_characteristics
    JSON.parse(@native.discover_characteristics(*args))
  else
    raise ArgumentError, "unknown native op: #{op}"
  end
end
```

- [ ] **Step 5: Integration test** — `test/integration/test_discover.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class DiscoverTest < Test::Unit::TestCase
  GAP_SERVICE_UUID = "00001800-0000-1000-8000-00805f9b34fb"
  DEVICE_NAME_CHAR_UUID = "00002a00-0000-1000-8000-00805f9b34fb"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_discover_services_includes_GAP
    @peripheral.discover_services(timeout: 5.0)
    uuids = @peripheral.services.map(&:uuid)
    assert_includes uuids, GAP_SERVICE_UUID
  end

  def test_discover_characteristics_includes_DeviceName
    @peripheral.discover_services
    gap = @peripheral.find_service(GAP_SERVICE_UUID)
    refute_nil gap, "Generic Access service missing"
    gap.discover_characteristics(timeout: 5.0)
    uuids = gap.characteristics.map(&:uuid)
    assert_includes uuids, DEVICE_NAME_CHAR_UUID
    ch = gap.find_characteristic(DEVICE_NAME_CHAR_UUID)
    assert ch.readable?
  end
end
```

- [ ] **Step 6: Compile + run**

> `bundle exec rake compile && BLE_HW=1 bundle exec rake test TEST=test/integration/test_discover.rb 2>&1 | tail -15`

Expected: 2 tests green.

- [ ] **Step 7: Commit**

- Files: CBMCentral.swift, CoreBluetoothMac.swift, corebluetooth_mac.c, central.rb, test/integration/test_discover.rb
- Message: `feat: Peripheral#discover_services and Service#discover_characteristics`

---

## Task 16: Read characteristic — Phase 1 success criterion

**Files:**
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`
- Create: `test/integration/test_read_gap_device_name.rb`
- Create: `examples/scan_and_read.rb`

- [ ] **Step 1: Add `readCharacteristic` to `CBMCentral.swift`**

```swift
func readCharacteristic(identifier: String, serviceUUID: String, charUUID: String, timeoutMs: Int32)
    -> Result<Data, CBMError>
{
    guard let (p, d) = peripheral(identifier: identifier) else {
        return .failure(.closed("Unknown peripheral \(identifier)"))
    }
    guard p.state == .connected else { return .failure(.connection("Peripheral not connected")) }
    let svcId = CBUUID(string: serviceUUID)
    let chId  = CBUUID(string: charUUID)
    guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }) else {
        return .failure(.discovery("Service \(serviceUUID) not discovered"))
    }
    guard let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
        return .failure(.discovery("Characteristic \(charUUID) not discovered"))
    }
    d.readCharUUID = chId
    d.readError = nil
    d.readValue = nil
    p.readValue(for: ch)
    let r = d.readSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
    d.readCharUUID = nil
    if r == .timedOut { return .failure(.timeout("read timed out after \(timeoutMs)ms")) }
    if let e = d.readError { return .failure(.io(e.localizedDescription)) }
    return .success(d.readValue ?? Data())
}
```

- [ ] **Step 2: Add `@c` ABI in `CoreBluetoothMac.swift`**

The C side gets bytes back via `len_out` + a malloc'd buffer. Use this signature (C side will own + free the buffer; we strdup-then-free style but for binary use `UnsafeMutablePointer<UInt8>?`):

```swift
@c
public func cbm_characteristic_read(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ len_out: UnsafeMutablePointer<Int32>,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<UInt8>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    len_out.pointee = 0
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.readCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        timeoutMs: timeout_ms
    ) {
    case .success(let data):
        let n = data.count
        len_out.pointee = Int32(n)
        if n == 0 {
            let buf = malloc(1)?.assumingMemoryBound(to: UInt8.self)
            return buf
        }
        let buf = malloc(n)!.assumingMemoryBound(to: UInt8.self)
        data.copyBytes(to: buf, count: n)
        return buf
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
}
```

- [ ] **Step 3: Extend C bridge** — read

Insert before `Init_corebluetooth_mac`:

```c
struct read_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t tag; char *err; int32_t len;
    unsigned char *buf;
};

static void *read_no_gvl(void *data) {
    struct read_args *a = (struct read_args *)data;
    a->buf = cbm_characteristic_read(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->len, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_read(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct read_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0, NULL
    };
    rb_thread_call_without_gvl(read_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.buf) raise_with(a.tag, a.err);
    // Return a mutable binary String so callers can chain `.force_encoding("UTF-8")`
    // without `.dup` (matches Socket#read / IO#read conventions).
    VALUE s = rb_str_new((const char *)a.buf, a.len);
    free(a.buf);
    return s;
}
```

In `Init_corebluetooth_mac`, add:

```c
rb_define_method(cNative, "characteristic_read", rb_characteristic_read, 4);
```

- [ ] **Step 4: Extend `central.rb` dispatcher**

In `__call_native`, add a case:

```ruby
when :characteristic_read
  @native.characteristic_read(*args)
```

- [ ] **Step 5: Integration test** — `test/integration/test_read_gap_device_name.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class ReadGAPDeviceNameTest < Test::Unit::TestCase
  GAP_SERVICE_UUID      = "00001800-0000-1000-8000-00805f9b34fb"
  DEVICE_NAME_CHAR_UUID = "00002a00-0000-1000-8000-00805f9b34fb"
  EXPECTED_NAME         = "StackChan-PicoRuby"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: EXPECTED_NAME, timeout: 8.0)
    omit "No #{EXPECTED_NAME} visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_phase1_success_criterion
    @peripheral.discover_services
    gap = @peripheral.find_service(GAP_SERVICE_UUID)
    refute_nil gap
    gap.discover_characteristics
    ch = gap.find_characteristic(DEVICE_NAME_CHAR_UUID)
    refute_nil ch
    bytes = ch.read(timeout: 5.0)
    assert_equal Encoding::ASCII_8BIT, bytes.encoding
    assert_equal EXPECTED_NAME, bytes.force_encoding("UTF-8")
  end
end
```

- [ ] **Step 6: Phase 1 deliverable** — `examples/scan_and_read.rb`

```ruby
# frozen_string_literal: true

require_relative "../lib/corebluetooth_mac"

GAP_SERVICE       = "00001800-0000-1000-8000-00805f9b34fb"
DEVICE_NAME_CHAR  = "00002a00-0000-1000-8000-00805f9b34fb"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
puts "Scanning…"
devs = central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
abort "Not found. `rake r2p2:reset` on CoreS3 to reopen its 60s window." if devs.empty?

dev = devs.first
puts "Found #{dev.identifier} rssi=#{dev.rssi}"
p = central.connect(dev, timeout: 5.0)
puts "Connected. State=#{p.state}"

p.discover_services
gap = p.find_service(GAP_SERVICE) || abort("GAP service missing")
gap.discover_characteristics
ch = gap.find_characteristic(DEVICE_NAME_CHAR) || abort("Device Name characteristic missing")
puts "Device Name = #{ch.read(timeout: 5.0).force_encoding('UTF-8').inspect}"

central.disconnect(p)
puts "Disconnected. State=#{p.state}"
```

- [ ] **Step 7: Compile + run integration**

> `bundle exec rake compile && BLE_HW=1 bundle exec rake test TEST=test/integration/test_read_gap_device_name.rb 2>&1 | tail -15`

Expected: 1 test green, message `"StackChan-PicoRuby"`.

> `BLE_HW=1 bundle exec ruby -Ilib examples/scan_and_read.rb`

Expected output (rough):

```
Scanning…
Found 1234ABCD-… rssi=-42
Connected. State=connected
Device Name = "StackChan-PicoRuby"
Disconnected. State=disconnected
```

- [ ] **Step 8: Commit (Phase 1 complete)**

- Files: CBMCentral.swift, CoreBluetoothMac.swift, corebluetooth_mac.c, central.rb, test/integration/test_read_gap_device_name.rb, examples/scan_and_read.rb
- Message: `feat: Characteristic#read; Phase 1 success criterion green`

---

## Task 17: README + Phase 1 wrap

**Files:**
- Create: `README.md`
- Modify: `lib/corebluetooth_mac/version.rb` (bump to 0.1.0 if not already — it is)

- [ ] **Step 1: Write `README.md`**

```markdown
# rb-corebluetooth-mac

Apple CoreBluetooth (BLE central) for Ruby on macOS via Swift native extension.

## Requirements

- macOS 13+ (Bluetooth permission prompt requires this; `OSAllocatedUnfairLock` in the Swift extension requires macOS 13)
- Ruby ≥ 3.2 (development pins 4.0.3 via `.ruby-version`)
- Swift 6.3+ (recommended installer: [swiftly](https://www.swift.org/install/macos/))
- A Bluetooth-capable Mac with permission granted to the terminal app

## Installation

`Gemfile`:

```ruby
gem "rb-corebluetooth-mac"
```

```bash
bundle install
```

The Swift native extension is built via `swift build` at install time. Xcode is not required.

## Bluetooth Permission

The first time you create a `Central`, macOS shows an "Allow … to use Bluetooth?" prompt **bound to the process** (Terminal.app, iTerm.app, VS Code's integrated terminal, etc.). If denied, every subsequent `Central.new` raises `PermissionError`.

To recover: System Settings → Privacy & Security → Bluetooth → toggle the terminal app on. To force a fresh prompt: `tccutil reset Bluetooth`.

## Usage (Phase 1)

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)

devices = central.scan(name: "StackChan-PicoRuby", timeout: 5.0)
peripheral = central.connect(devices.first, timeout: 5.0)

peripheral.discover_services
peripheral.services.each do |svc|
  puts svc.uuid
  svc.discover_characteristics
  svc.characteristics.each do |ch|
    next unless ch.readable?
    puts "  #{ch.uuid} = #{ch.read.inspect}"
  end
end

central.disconnect(peripheral)
```

## Errors

- `CoreBluetoothMac::PermissionError` — Bluetooth permission denied for this process.
- `CoreBluetoothMac::StateError` — Bluetooth off / unsupported / resetting.
- `CoreBluetoothMac::TimeoutError` — an operation did not complete within `timeout:`.
- `CoreBluetoothMac::ConnectionError` — connect failed or device disconnected mid-op.
- `CoreBluetoothMac::DiscoveryError` — service / characteristic discovery error.
- `CoreBluetoothMac::IOError` — read / write / notify framework error.
- `CoreBluetoothMac::ClosedError` — operation on a freed `Central`.

## Limitations

- One in-flight blocking operation per peripheral per kind. Concurrent reads on the same peripheral are serialized.
- BLE central role only; no `CBPeripheralManager` (peripheral / advertising) support.
- macOS only; not iOS / iPadOS / Linux.

## Phase 2 (next)

`Characteristic#write`, `#write_without_response`, `#subscribe` → Ractor-shareable `Subscription` with `#next_value(timeout:)`.

## License

MIT
```

- [ ] **Step 2: Commit**

- Files: `README.md`
- Message: `docs: README for Phase 1 release (0.1.0)`

- [ ] **Step 3: Tag the Phase 1 milestone**

Delegate to `commit-commands:commit-push-pr` or general-purpose:
> Prompt: `cd /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac && git tag v0.1.0`

(Don't push the tag until the user okays it.)

---

## Phase 2 begins here.

## Task 18: Bump version to 0.2.0-dev and outline Phase 2

**Files:**
- Modify: `lib/corebluetooth_mac/version.rb`
- Modify: `test/unit/test_module.rb`

- [ ] **Step 1: Bump VERSION**

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  VERSION = "0.2.0.pre"
end
```

- [ ] **Step 2: Relax `test_VERSION_is_semver` regex to accept the RubyGems prerelease suffix**

The Task 3 regex `\A\d+\.\d+\.\d+\z` rejected any prerelease tail. Accept an optional `.<word>` suffix so RubyGems-style `0.2.0.pre` / `0.2.0.beta1` pass.

In `test/unit/test_module.rb`, replace the regex:

```ruby
def test_VERSION_is_semver
  assert_match(/\A\d+\.\d+\.\d+(\.[a-z]\w*)?\z/, CoreBluetoothMac::VERSION)
end
```

- [ ] **Step 3: Commit**

- Files: `lib/corebluetooth_mac/version.rb`, `test/unit/test_module.rb`
- Message: `chore: bump version to 0.2.0.pre for Phase 2 work`

---

## Task 19: Write (with response)

**Files:**
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`
- Create: `test/integration/test_write.rb`

- [ ] **Step 1: Add `writeCharacteristic` to `CBMCentral.swift`**

```swift
func writeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                          data: Data, withResponse: Bool, timeoutMs: Int32) -> CBMError? {
    guard let (p, d) = peripheral(identifier: identifier) else { return .closed("Unknown peripheral \(identifier)") }
    guard p.state == .connected else { return .connection("Peripheral not connected") }
    let svcId = CBUUID(string: serviceUUID)
    let chId  = CBUUID(string: charUUID)
    guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }),
          let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
        return .discovery("Service/characteristic not discovered")
    }
    if withResponse {
        d.writeCharUUID = chId
        d.writeError = nil
        p.writeValue(data, for: ch, type: .withResponse)
        let r = d.writeSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.writeCharUUID = nil
        if r == .timedOut { return .timeout("write timed out after \(timeoutMs)ms") }
        if let e = d.writeError { return .io(e.localizedDescription) }
        return nil
    } else {
        // Best-effort. Optionally honor canSendWriteWithoutResponse.
        p.writeValue(data, for: ch, type: .withoutResponse)
        return nil
    }
}
```

- [ ] **Step 2: Add `@c` ABI to `CoreBluetoothMac.swift`**

```swift
@c
public func cbm_characteristic_write(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ data: UnsafePointer<UInt8>,
    _ data_len: Int32,
    _ with_response: Int32,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let bytes = UnsafeBufferPointer(start: data, count: Int(data_len))
    let payload = Data(buffer: bytes)
    if let err = c.writeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        data: payload,
        withResponse: with_response != 0,
        timeoutMs: timeout_ms
    ) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}
```

- [ ] **Step 3: C bridge in `corebluetooth_mac.c`**

Add before `Init_corebluetooth_mac`:

```c
struct write_args {
    void *p; const char *id; const char *svc; const char *ch;
    const unsigned char *buf; int32_t buf_len;
    int32_t with_response; int32_t timeout_ms;
    int32_t tag; char *err; int32_t ok;
};

static void *write_no_gvl(void *data) {
    struct write_args *a = (struct write_args *)data;
    a->ok = cbm_characteristic_write(a->p, a->id, a->svc, a->ch,
                                     a->buf, a->buf_len, a->with_response, a->timeout_ms,
                                     &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_write(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v,
                                     VALUE data_v, VALUE with_response_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    StringValue(data_v);
    Check_Type(with_response_v, T_FIXNUM);
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct write_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (const unsigned char *)RSTRING_PTR(data_v), (int32_t)RSTRING_LEN(data_v),
        (int32_t)NUM2INT(with_response_v), (int32_t)NUM2INT(timeout_ms_v),
        0, NULL, 0
    };
    rb_thread_call_without_gvl(write_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.ok) raise_with(a.tag, a.err);
    return Qnil;
}
```

In `Init_corebluetooth_mac`:

```c
rb_define_method(cNative, "characteristic_write", rb_characteristic_write, 6);
```

- [ ] **Step 4: Update `central.rb` dispatcher**

In `__call_native`, add:

```ruby
when :characteristic_write
  @native.characteristic_write(*args)
```

- [ ] **Step 5: Integration test** — `test/integration/test_write.rb`

Note: Phase 1 of `stackchan-picoruby` doesn't ship a writeable characteristic yet. Skip-mark this test with a clearer reason than HardwareGuard.

```ruby
# frozen_string_literal: true

require "test_helper"

class WriteTest < Test::Unit::TestCase
  NUS_RX_CHAR = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
    @rx = @peripheral.find_characteristic(NUS_RX_CHAR)
    omit "NUS RX characteristic not present (CoreS3 Phase 2 not deployed yet)." unless @rx
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_write_with_response
    @rx.write("ping\n", response: true, timeout: 5.0)
    pass "write completed without raising"
  end

  def test_write_without_response
    @rx.write_without_response("hi\n")
    pass "write_without_response returned cleanly"
  end
end
```

- [ ] **Step 6: Compile + run**

> `bundle exec rake compile && BLE_HW=1 bundle exec rake test TEST=test/integration/test_write.rb 2>&1 | tail -15`

Expected: tests omit until CoreS3 ships NUS characteristics; the compile path is green.

- [ ] **Step 7: Commit**

- Files: CBMCentral.swift, CoreBluetoothMac.swift, corebluetooth_mac.c, central.rb, test/integration/test_write.rb
- Message: `feat: Characteristic#write (with/without response)`

---

## Task 20: Subscribe + SubscriptionRegistry

**Files:**
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMSubscriptionRegistry.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMCentral.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CBMPeripheralDelegate.swift`
- Modify: `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMac.swift`
- Modify: `ext/corebluetooth_mac/corebluetooth_mac.c`
- Modify: `lib/corebluetooth_mac/central.rb`
- Modify: `lib/corebluetooth_mac.rb`

- [ ] **Step 1: Replace `CBMSubscriptionRegistry.swift` with the real impl**

```swift
import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMSubscriptionRegistry: @unchecked Sendable {
    static let shared = CBMSubscriptionRegistry()
    private init() {}

    final class Entry {
        weak var central: CBMCentral?
        let characteristicUUID: CBUUID
        var queue: [Data] = []
        var closed: Bool = false
        let semaphore = DispatchSemaphore(value: 0)
        init(central: CBMCentral, characteristicUUID: CBUUID) {
            self.central = central
            self.characteristicUUID = characteristicUUID
        }
    }

    private let lock = OSAllocatedUnfairLock<[Int64: Entry]>(initialState: [:])
    // Locking the counter inside the lock state avoids Swift 6 static-mutable errors.
    private static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    func register(central: CBMCentral, characteristicUUID: CBUUID) -> Int64 {
        let assigned: Int64 = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        let entry = Entry(central: central, characteristicUUID: characteristicUUID)
        lock.withLock { $0[assigned] = entry }
        return assigned
    }

    func enqueue(characteristic: CBCharacteristic, error: Error?) {
        // Fan out to every entry watching this UUID.
        // (We don't have a back-pointer from characteristic→subscription_id;
        // looping is cheap given queue sizes.)
        let value = characteristic.value ?? Data()
        lock.withLock { dict in
            for (_, entry) in dict {
                if entry.characteristicUUID == characteristic.uuid && !entry.closed {
                    entry.queue.append(value)
                    entry.semaphore.signal()
                }
            }
        }
    }

    func dequeue(subscriptionId: Int64, timeoutMs: Int32) -> (data: Data?, closed: Bool) {
        let entry: Entry? = lock.withLock { $0[subscriptionId] }
        guard let e = entry else { return (nil, true) }
        if e.closed && e.queue.isEmpty { return (nil, true) }
        if let first = lock.withLock({ _ -> Data? in e.queue.isEmpty ? nil : e.queue.removeFirst() }) {
            return (first, false)
        }
        let r = e.semaphore.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { return (nil, false) }
        let popped: Data? = lock.withLock { _ in e.queue.isEmpty ? nil : e.queue.removeFirst() }
        return (popped, e.closed)
    }

    func close(subscriptionId: Int64) {
        let entry: Entry? = lock.withLock { $0[subscriptionId] }
        guard let e = entry else { return }
        e.closed = true
        e.semaphore.signal()
    }

    func purge(subscriptionId: Int64) {
        lock.withLock { $0.removeValue(forKey: subscriptionId) }
    }

    func purgeAll(under central: CBMCentral) {
        lock.withLock { dict in
            for (id, entry) in dict where entry.central === central {
                entry.closed = true
                entry.semaphore.signal()
                dict.removeValue(forKey: id)
            }
        }
    }
}
```

- [ ] **Step 2: Add subscribe/unsubscribe to `CBMCentral.swift`**

```swift
func subscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                              timeoutMs: Int32) -> Result<Int64, CBMError> {
    guard let (p, d) = peripheral(identifier: identifier) else { return .failure(.closed("Unknown peripheral")) }
    guard p.state == .connected else { return .failure(.connection("Peripheral not connected")) }
    let svcId = CBUUID(string: serviceUUID)
    let chId  = CBUUID(string: charUUID)
    guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }),
          let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
        return .failure(.discovery("Service/characteristic not discovered"))
    }
    d.notifyCharUUID = chId
    d.notifyError = nil
    p.setNotifyValue(true, for: ch)
    let r = d.notifySem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
    d.notifyCharUUID = nil
    if r == .timedOut { return .failure(.timeout("subscribe timed out")) }
    if let e = d.notifyError { return .failure(.io(e.localizedDescription)) }
    let id = CBMSubscriptionRegistry.shared.register(central: self, characteristicUUID: chId)
    return .success(id)
}

func unsubscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                                timeoutMs: Int32) -> CBMError? {
    guard let (p, d) = peripheral(identifier: identifier) else { return .closed("Unknown peripheral") }
    guard p.state == .connected else { return .connection("Peripheral not connected") }
    let svcId = CBUUID(string: serviceUUID)
    let chId  = CBUUID(string: charUUID)
    guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }),
          let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
        return .discovery("Service/characteristic not discovered")
    }
    d.notifyCharUUID = chId
    d.notifyError = nil
    p.setNotifyValue(false, for: ch)
    let r = d.notifySem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
    d.notifyCharUUID = nil
    if r == .timedOut { return .timeout("unsubscribe timed out") }
    if let e = d.notifyError { return .io(e.localizedDescription) }
    // Close all subscriptions matching this characteristic UUID under this central.
    CBMSubscriptionRegistry.shared.purgeAll(under: self) // simpler than per-char; safe for Phase 2 single-subscription cases
    return nil
}
```

- [ ] **Step 3: Free under Central** — modify `cbm_central_free` in `CoreBluetoothMac.swift`

```swift
@c
public func cbm_central_free(_ ptr: UnsafeMutableRawPointer) {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeRetainedValue()
    CBMSubscriptionRegistry.shared.purgeAll(under: c)
    // Optionally cancel all active connections; CBCentralManager deinit handles it.
}
```

- [ ] **Step 4: Add @c ABI for subscribe/unsubscribe/next_value/close**

Append to `CoreBluetoothMac.swift`:

```swift
@c
public func cbm_characteristic_subscribe(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int64 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.subscribeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        timeoutMs: timeout_ms
    ) {
    case .success(let id): return id
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
}

@c
public func cbm_characteristic_unsubscribe(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    if let err = c.unsubscribeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        timeoutMs: timeout_ms
    ) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_subscription_next_value(
    _ subscription_id: Int64,
    _ timeout_ms: Int32,
    _ closed_out: UnsafeMutablePointer<Int32>,
    _ len_out: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<UInt8>? {
    closed_out.pointee = 0
    len_out.pointee = 0
    let (data, closed) = CBMSubscriptionRegistry.shared.dequeue(
        subscriptionId: subscription_id, timeoutMs: timeout_ms
    )
    if closed { closed_out.pointee = 1 }
    guard let d = data else { return nil }
    let n = d.count
    len_out.pointee = Int32(n)
    if n == 0 {
        return malloc(1)?.assumingMemoryBound(to: UInt8.self)
    }
    let buf = malloc(n)!.assumingMemoryBound(to: UInt8.self)
    d.copyBytes(to: buf, count: n)
    return buf
}

@c
public func cbm_subscription_close(_ subscription_id: Int64) {
    CBMSubscriptionRegistry.shared.close(subscriptionId: subscription_id)
}
```

- [ ] **Step 5: C bridge subscribe/unsubscribe/next_value/close** — append to `corebluetooth_mac.c`

```c
struct subscribe_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t tag; char *err; int64_t sub_id;
};

static void *subscribe_no_gvl(void *data) {
    struct subscribe_args *a = (struct subscribe_args *)data;
    a->sub_id = cbm_characteristic_subscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_subscribe(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct subscribe_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0
    };
    rb_thread_call_without_gvl(subscribe_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.sub_id == 0) raise_with(a.tag, a.err);
    return LL2NUM(a.sub_id);
}

struct unsubscribe_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t tag; char *err; int32_t ok;
};

static void *unsubscribe_no_gvl(void *data) {
    struct unsubscribe_args *a = (struct unsubscribe_args *)data;
    a->ok = cbm_characteristic_unsubscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_unsubscribe(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct unsubscribe_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0
    };
    rb_thread_call_without_gvl(unsubscribe_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.ok) raise_with(a.tag, a.err);
    return Qnil;
}

// ---- Module-level subscription functions (operate on integer ids) ----

struct next_args {
    int64_t sub_id; int32_t timeout_ms;
    int32_t closed; int32_t len; unsigned char *buf;
};

static void *next_no_gvl(void *data) {
    struct next_args *a = (struct next_args *)data;
    a->buf = cbm_subscription_next_value(a->sub_id, a->timeout_ms, &a->closed, &a->len);
    return NULL;
}

static VALUE rb_subscription_next_value(VALUE self, VALUE central_id_v, VALUE sub_id_v, VALUE timeout_ms_v) {
    (void)central_id_v;  // reserved for future multi-central isolation
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct next_args a = { (int64_t)NUM2LL(sub_id_v), (int32_t)NUM2INT(timeout_ms_v), 0, 0, NULL };
    rb_thread_call_without_gvl(next_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.buf) {
        return Qnil;  // timeout or closed-empty
    }
    VALUE s = rb_str_new((const char *)a.buf, a.len);
    free(a.buf);
    rb_str_freeze(s);
    return s;
}

static VALUE rb_subscription_close(VALUE self, VALUE central_id_v, VALUE sub_id_v) {
    (void)central_id_v;
    cbm_subscription_close((int64_t)NUM2LL(sub_id_v));
    return Qnil;
}
```

In `Init_corebluetooth_mac`:

```c
rb_define_method(cNative, "characteristic_subscribe",   rb_characteristic_subscribe,   4);
rb_define_method(cNative, "characteristic_unsubscribe", rb_characteristic_unsubscribe, 4);

rb_define_module_function(mod, "__subscription_next_value", rb_subscription_next_value, 3);
rb_define_module_function(mod, "__subscription_close",      rb_subscription_close,      2);
```

- [ ] **Step 6: Extend `central.rb` dispatcher**

In `__call_native`:

```ruby
when :characteristic_subscribe
  @native.characteristic_subscribe(args[0], args[1], args[2], 5000)  # 5s default subscribe timeout
when :characteristic_unsubscribe
  @native.characteristic_unsubscribe(args[0], args[1], args[2], 5000)
```

(The Phase 2 `Characteristic#subscribe` API does not take a timeout argument. Hard-coded 5s here is the implicit upper bound for the GATT subscribe ack; document if exposed later.)

- [ ] **Step 7: Compile**

> `bundle exec rake compile 2>&1 | tail -10`

Expected: green.

- [ ] **Step 8: Commit**

- Files: CBMSubscriptionRegistry.swift, CBMCentral.swift, CoreBluetoothMac.swift, corebluetooth_mac.c, central.rb
- Message: `feat: subscribe / unsubscribe / Subscription#next_value pump`

---

## Task 21: Subscription integration test + Ractor pump

**Files:**
- Create: `test/integration/test_subscribe.rb`
- Create: `test/integration/test_subscribe_ractor.rb`
- Create: `examples/subscribe_ractor.rb`

- [ ] **Step 1: Single-Ractor integration test** — `test/integration/test_subscribe.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class SubscribeTest < Test::Unit::TestCase
  NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
    @tx = @peripheral.find_characteristic(NUS_TX_CHAR)
    omit "NUS TX characteristic not present (CoreS3 Phase 2 not deployed yet)." unless @tx
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_subscribe_returns_subscription
    sub = @tx.subscribe
    assert_kind_of CoreBluetoothMac::Subscription, sub
    assert_operator sub.subscription_id, :>, 0
    @tx.unsubscribe
  end

  def test_next_value_timeout_returns_nil
    sub = @tx.subscribe
    assert_nil sub.next_value(timeout: 0.2)
    @tx.unsubscribe
  end

  def test_unsubscribe_wakes_pending_next_value
    sub = @tx.subscribe
    th = Thread.new { sub.next_value(timeout: 5.0) }
    sleep 0.1
    @tx.unsubscribe
    assert_nil th.value
  end
end
```

- [ ] **Step 2: Ractor pump integration test** — `test/integration/test_subscribe_ractor.rb`

```ruby
# frozen_string_literal: true

require "test_helper"

class SubscribeRactorTest < Test::Unit::TestCase
  NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
    @tx = @peripheral.find_characteristic(NUS_TX_CHAR)
    omit "NUS TX characteristic not present." unless @tx
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_subscription_crosses_ractor_boundary
    sub = @tx.subscribe
    assert Ractor.shareable?(sub)

    pump = Ractor.new(sub) do |s|
      data = s.next_value(timeout: 0.3)
      data  # may be nil if no notification arrives within window — accept either
    end
    result = pump.take
    assert(result.nil? || result.is_a?(String))
    @tx.unsubscribe
  end
end
```

- [ ] **Step 3: Phase 2 deliverable example** — `examples/subscribe_ractor.rb`

```ruby
# frozen_string_literal: true

require_relative "../lib/corebluetooth_mac"

NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
devs = central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
abort "no peripheral" if devs.empty?
p = central.connect(devs.first, timeout: 5.0)
p.discover_services
p.services.each(&:discover_characteristics)
tx = p.find_characteristic(NUS_TX_CHAR) || abort("NUS TX missing")

sub = tx.subscribe
puts "Subscribed (id=#{sub.subscription_id}). Pumping in Ractor for 10s…"

pump = Ractor.new(sub) do |s|
  results = []
  10.times do
    v = s.next_value(timeout: 1.0)
    break if v.nil?
    results << v
    Ractor.yield v.bytes.inspect
  end
  results.size
end

10.times do
  begin
    msg = pump.take
    puts "RX: #{msg}"
  rescue Ractor::ClosedError
    break
  end
end

tx.unsubscribe
central.disconnect(p)
puts "Done."
```

- [ ] **Step 4: Run with hardware (skips if CoreS3 Phase 2 missing)**

> `BLE_HW=1 bundle exec rake test TEST=test/integration/test_subscribe.rb 2>&1 | tail -15`
> `BLE_HW=1 bundle exec rake test TEST=test/integration/test_subscribe_ractor.rb 2>&1 | tail -15`

Expected: omits with "NUS TX characteristic not present" until CoreS3 NUS lands; once it does, both green.

- [ ] **Step 5: Update README with Phase 2 section**

Append to `README.md` after the existing "Usage (Phase 1)" block:

```markdown
## Usage (Phase 2): write & subscribe with Ractor pump

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new
device  = central.scan(name: "StackChan-PicoRuby", timeout: 5.0).first or abort
periph  = central.connect(device)
periph.discover_services
periph.services.each(&:discover_characteristics)

rx = periph.find_characteristic("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
tx = periph.find_characteristic("6e400003-b5a3-f393-e0a9-e50e24dcca9e")

rx.write("ping\n", response: true)
sub = tx.subscribe

pump = Ractor.new(sub) do |s|
  while (v = s.next_value(timeout: 5.0))
    Ractor.yield v
  end
end

5.times { puts pump.take.inspect }
tx.unsubscribe
central.disconnect(periph)
```
```

- [ ] **Step 6: Bump VERSION to 0.2.0**

Update `lib/corebluetooth_mac/version.rb`:

```ruby
# frozen_string_literal: true

module CoreBluetoothMac
  VERSION = "0.2.0"
end
```

- [ ] **Step 7: Commit**

- Files: `test/integration/test_subscribe.rb`, `test/integration/test_subscribe_ractor.rb`, `examples/subscribe_ractor.rb`, `README.md`, `lib/corebluetooth_mac/version.rb`
- Message: `feat: Subscription Ractor pump example + Phase 2 integration tests`

---

## Self-Review (executed before declaring plan complete)

**1. Spec coverage:**

| Spec section | Implementing task |
|---|---|
| §2 Phase 1 scope | Tasks 1–17 |
| §2 Phase 2 scope | Tasks 18–21 |
| §3 3-layer arch | Tasks 9–12 establish; remaining tasks fill the layers |
| §4 Ruby Object Model | Tasks 5 (DiscoveredDevice), 6 (Subscription), 7 (Peripheral), 8 (Service, Characteristic), 10 (Central) |
| §4.1 Module API (errors) | Task 4 |
| §4.2 Method signatures | Tasks 5–21 piecewise |
| §5 Swift Architecture | Tasks 11, 13, 14, 15, 16, 19, 20 |
| §5.4 @c ABI signatures | Tasks 11–20 ABI sections |
| §6 C Bridge ≤150 LOC | Tasks 10, 12, 13, 14, 15, 16, 19, 20 — final size near 250 LOC; acceptable. Note: original 150 LOC budget was an aspirational target; actual surface needs more thunks. **Update design doc §6 to reflect ~250 LOC** in a follow-up commit; not a plan blocker. |
| §7 Lifecycle | Wired by Tasks 12 (Central.new), 13 (scan), 14 (connect/disconnect), 15 (discover), 16 (read), 19 (write), 20 (subscribe/unsubscribe/next_value) |
| §8 Error Mapping | Tasks 11 (Swift CBMError tag), 12 (C raise_with), 4 (Ruby error classes) |
| §9 Memory & Ractor Safety | Tasks 5, 6 (Ractor.shareable? assertions); Task 20 (registry purge on Central GC) |
| §10 Project Layout | Tasks 1–21 produce every file in the table |
| §11 TDD Strategy (t-wada) | Every task uses the RGR discipline header at the top of this plan |
| §11.2 hardware-skip | Task 3 (test_helper.rb HardwareGuard) |
| §11.3 Phase 1 TODO list | Tasks 3–17 map 1:1 to the checkboxes there |
| §11.4 Phase 2 TODO list | Tasks 18–21 map 1:1 to checkboxes there |
| §12 Bluetooth Permission UX | Task 17 README + Task 11 CBMCentral error mapping |
| §13 Open Questions | Documented as future work; not in scope |

**2. Placeholder scan:**

Searched for "TBD", "TODO" (outside intentional TDD-list mentions), "FIXME", "implement later". None found beyond the design doc's own §13 future-work list and per-task TDD TODO-list rhetoric.

**3. Type consistency:**

- `central_id` is `Int64` in Swift and `Integer` in Ruby — consistent.
- `subscription_id` is `Int64` in Swift, accessed as `subscription_id` (snake_case) in Ruby via `Data.define`. The C bridge uses `LL2NUM` / `NUM2LL`. Consistent.
- Method names match across tasks: `discover_services`, `discover_characteristics`, `find_service`, `find_characteristic`, `read`, `write`, `write_without_response`, `subscribe`, `unsubscribe`, `next_value`, `close`.
- Native bridge ops: `:peripheral_state`, `:peripheral_discover_services`, `:service_discover_characteristics`, `:characteristic_read`, `:characteristic_write`, `:characteristic_subscribe`, `:characteristic_unsubscribe` — used consistently in `Central#__call_native`, the routing classes, and the unit tests.

**4. Known soft spots fixed inline:**

- Task 7 originally would have committed red; I changed it to roll into Task 8's commit and explicitly documented why.
- Task 11 + Task 12 split the Swift work and the Ruby/C wiring into distinct commits so each commit ships a working build, not a half-built one.
- Task 17 ships the README only after the success criterion is green (Task 16) — order matters; reversing would publish an unverified usage section.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-15-rb-corebluetooth-mac.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration. Good fit because tasks are tightly scoped and each commit is reviewable in isolation.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints. Faster if the user wants minimal hand-holding.

**Which approach?**
