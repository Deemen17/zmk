# ZMK Firmware Development Guide for AI Agents

ZMK (Zephyr Mechanical Keyboard) is a wireless mechanical keyboard firmware built on top of Zephyr OS. This guide helps AI agents understand the architecture and contribute effectively.

## Project Structure

```
app/                          # Main firmware application
├── src/                      # Core firmware source (40+ .c files)
│   ├── behaviors/            # 25+ behavior implementations (hold-tap, combos, layers, etc.)
│   ├── events/               # Event definitions and handlers
│   ├── split/                # Split keyboard logic (central/peripheral/bluetooth)
│   ├── display/              # Display and UI rendering (LVGL-based)
│   ├── pointing/             # Mouse/trackpad input handling
│   ├── studio/               # ZMK Studio RPC communication
│   └── *.c                   # Core modules: keymap, HID, BLE, USB, sensors, battery, etc.
├── include/zmk/              # Public API headers
├── module/                   # Zephyr module extensions (drivers, test-behaviors)
├── keymap-module/            # Keymap configuration DTS processing
├── boards/                   # Board definitions and shield overlays (40+ keyboards)
├── dts/                      # Device tree definitions (behaviors, bindings, layouts)
├── tests/                    # Unit tests using native_sim and nrf52_bsim simulators
├── Kconfig*                  # Build configuration options
└── west.yml                  # Manifest: Zephyr pinned at v4.1.0+zmk-fixes, LVGL included
```

## Architecture: Event-Driven Behavior System

ZMK's core design revolves around **event propagation** through a pub-sub listener system:

1. **Events** (in `include/zmk/events/`) are defined with `ZMK_EVENT_DECLARE(name)` macro
2. **Listeners** subscribe via `ZMK_LISTENER(module_name, callback)` and `ZMK_SUBSCRIPTION(module, event_type)`
3. Events propagate with `ZMK_EVENT_RAISE(event)` and listeners can handle (return `ZMK_EV_EVENT_HANDLED`) or bubble (return `ZMK_EV_EVENT_BUBBLE`)
4. Special flow: `ZMK_EVENT_RAISE_AFTER(event, previous_listener)` ensures ordered processing

**Example flow**: Key press → `position_state_changed` event → behavior system → `keycode_state_changed` event → HID layer → endpoints (USB/BLE).

See `/include/zmk/event_manager.h` for the complete macro API. This pattern enables loose coupling between keyboard scanning, behaviors, split communication, and output transports.

## Behaviors: The Extensibility Pattern

Behaviors are Zephyr devices implementing a **behavior driver interface**:

- Located in `src/behaviors/behavior_*.c` (one per behavior type)
- Each follows pattern: `#define DT_DRV_COMPAT zmk_behavior_<name>`
- Behaviors are instantiated via **device tree bindings** (`dts/behaviors/*.dtsi`) with parameters
- Two core interfaces:
  - `struct behavior_driver_api` with `on_binding_pressed()` / `on_binding_released()` callbacks
  - Nested behavior invocation: behaviors can trigger other behaviors (e.g., hold-tap triggers hold/tap action)

**Example**: `behavior_hold_tap.c` (~885 lines) demonstrates complex behavior state machine, timer management, and event capture.

Structure follows `ZMK_BEHAVIOR_BINDING` with param1/param2 (e.g., mod key + tap behavior for mod-tap).

## Build System

Uses **CMake** + **Zephyr build system** + **west** (workspace tool):

**Standard build**:
```bash
west build -d build/mybuild -b <board> -s <source> -- <cmake-args>
```

**Building from zmk-config folder** (external keymap):
```bash
west build -d build/left -p -b nice_nano -- -DZMK_CONFIG="/path/to/zmk-config" -DSHIELD=kyria_left
```

The `ZMK_CONFIG` path resolution (priority order):
1. CMake cache (previous build) — warns if changed without pristine rebuild (`west build -p`)
2. CLI argument `-DZMK_CONFIG=...`
3. Environment variable `$ZMK_CONFIG`
4. Default in CMakeLists.txt (if any)

The `zmk-config` folder structure supports:
- **Keymaps**: `<zmk-config>/<shield|board>.keymap` or `default.keymap`
- **Overlays**: `<zmk-config>/<shield|board>.overlay` — device tree customizations
- **Config files**: `<zmk-config>/<shield|board>.conf` — Kconfig settings
- **Boards/DTS** (deprecated): `<zmk-config>/boards/` and `<zmk-config>/dts/` — recommend using modules instead

Search priority for keymap: `shield_name` → partial shields → board → board_dir_name

**Key patterns**:
- `-DSHIELD=shield_name` for split keyboards (left/right halves)
- `-DZMK_CONFIG=path/to/config` for external keymaps, conf files, and overlays
- `target_sources_ifdef(CONFIG_ZMK_FEATURE ...)` in CMakeLists.txt enables conditional compilation
- Features controlled by `Kconfig` (checked in CMakeLists.txt)

**Critical**: `CMakeLists.txt` line 6 includes extra modules: `module/` and `keymap-module/` are always added. `ZMK_EXTRA_MODULES` env var adds external modules.

## Testing Patterns

Two test harnesses (both shell scripts):

**Unit tests** (`run-test.sh`):
- Builds with `-b native_sim/native/64` (native simulator, not hardware)
- Finds tests via `find tests -name native_sim.keymap`
- Expects `tests/testcase/keycode_events.snapshot` for output comparison
- Environment: `ZMK_TESTS_AUTO_ACCEPT=y` to auto-update snapshots, `J=N` for parallel jobs

**BLE tests** (`run-ble-test.sh`):
- Requires `BSIM_OUT_PATH` environment variable (nrf52 simulator path)
- Builds with `-b nrf52_bsim` for Bluetooth simulation
- Central + peripheral with `peripheral*.overlay` files for multiple roles
- Comparison via `events.patterns` sed filter + `snapshot.log`

**Run individual test**: `./run-test.sh tests/hold-tap` or `./run-ble-test.sh tests/ble/split`

Core coverage matrix in `core-coverage.yml` defines continuous integration builds (multiple boards/shields/configs).

## Configuration: Kconfig & DTS

**Kconfig** (`Kconfig`, `Kconfig.behaviors`, `Kconfig.defaults`):
- Defines optional features (e.g., `CONFIG_ZMK_DISPLAY`, `CONFIG_ZMK_SPLIT`, `CONFIG_ZMK_BEHAVIOR_HOLD_TAP`)
- HID report type (HKRO vs NKRO), BLE/USB settings, feature flags
- Device tree bindings use `#if IS_ENABLED(CONFIG_ZMK_FEATURE)` guards

**Device Tree** (`dts/behaviors.dtsi`, `dts/bindings/`):
- Behaviors defined as YAML bindings in `dts/bindings/behaviors/`
- Keyboard layout defined in keymap file (e.g., `config/keymap.json` parsed into `keymaps[]` device tree structure)
- Boards (`boards/`) define hardware: MCU, pinouts, peripherals
- Shields (`boards/shields/`) define keyboard-specific overlays (left/right halves for split boards)

## Split Keyboard Architecture

Split keyboard logic separates the firmware for left (central) vs right (peripheral):

- **Central** (`src/split/central.c`): Connects to peripheral via BLE, transmits matrix events, receives sensor data
- **Peripheral** (`src/split/peripheral.c`): Scans its matrix, sends to central, receives commands
- **Bluetooth** (`src/split/bluetooth/`): Handles pairing, disconnection, power management
- **Wired** (`src/split/wired/`): UART-based communication option

Build control: `CONFIG_ZMK_SPLIT_ROLE_CENTRAL` / `CONFIG_ZMK_SPLIT_ROLE_PERIPHERAL` determines which firmware to compile. User typically builds both halves with different configs pointing to same keymap.

## Critical Developer Patterns

1. **System Calls**: Behaviors use Zephyr system calls. See `zephyr_syscall_header(...)` in CMakeLists.txt for syscall definitions (behavior.h, input_processor.h, ext_power.h).

2. **Logging**: All modules use `LOG_MODULE_REGISTER(zmk, CONFIG_ZMK_LOG_LEVEL)`. Check logs via `LOG_INF("msg")`, visible in test output with `-DCONFIG_ASSERT=y`.

3. **Linker Sections**: Custom linker scripts load event types and subscriptions at compile time:
   - `include/linker/zmk-behaviors.ld` (behavior device registry)
   - `include/linker/zmk-events.ld` (event type registry)
   - These enable runtime event dispatch without hardcoded dependencies.

4. **Conditional Compilation**: Heavy use of `_ifdef` suffixes in CMake and `#if IS_ENABLED()` in C. Check `Kconfig.defaults` to understand default-on features (e.g., split is optional).

5. **Module/Keymap-Module**: `module/` is the ZMK extension module (drivers, behaviors). `keymap-module/` processes keymap device tree syntax. Both included in `ZEPHYR_EXTRA_MODULES`.

## Building from zmk-config Folder

A `zmk-config` is an external configuration folder containing keymaps, overlays, and Kconfig settings for custom keyboards. This keeps the main firmware separate from user customizations.

**Typical zmk-config folder structure**:
```
zmk-config/
├── config/
│   ├── kyria_left.keymap          # Keymap for left half
│   ├── kyria_right.keymap         # Keymap for right half
│   ├── kyria.conf                 # Config options (Kconfig)
│   ├── kyria.overlay              # Device tree overrides
│   ├── default.conf               # Fallback config
│   └── (deprecated) boards/       # Old way to add custom boards
└── (deprecated) dts/              # Old way to add DTS overlays
```

**Build command**:
```bash
west build -d build/left -p -b nice_nano -- -DZMK_CONFIG="/absolute/path/to/zmk-config" -DSHIELD=kyria_left
```

**Critical points**:
1. Use **absolute paths** or paths relative to the workspace root for `-DZMK_CONFIG`
2. Must use `-p` (pristine) when changing `ZMK_CONFIG` path between builds
3. Keymap discovery: Build system searches for `<shield>.keymap` or `default.keymap` in `ZMK_CONFIG` first, then in app source
4. Config file search: `<shield>_<board>.conf` → `<shield>.conf` → `<board>.conf` → `default.conf`
5. Device tree overlay search: `<shield>_<board>.overlay` → `<shield>.overlay` → `<board>.overlay` → `default.overlay`

**Using environment variable** (persists across rebuilds):
```bash
export ZMK_CONFIG="/absolute/path/to/zmk-config"
west build -d build/left -p -b nice_nano -- -DSHIELD=kyria_left
```

**Real example** (split keyboard with custom config):
```bash
# Build left half with custom zmk-config
west build -d build/left -p -b nice_nano -- \
  -DZMK_CONFIG="$HOME/keyboards/zmk-config" \
  -DSHIELD=kyria_left

# Build right half
west build -d build/right -p -b nice_nano -- \
  -DZMK_CONFIG="$HOME/keyboards/zmk-config" \
  -DSHIELD=kyria_right
```

## Common Workflows

**Add a new behavior**:
1. Create `src/behaviors/behavior_myname.c` with driver implementation
2. Add YAML binding in `dts/bindings/behaviors/zmk,behavior-myname.yaml`
3. Create default instance in `dts/behaviors/myname.dtsi`
4. Add `target_sources` to `src/behaviors/CMakeLists.txt`
5. Add Kconfig option (optional, in `Kconfig.behaviors` or `Kconfig`)
6. Test with unit test in `tests/myname/` using native_sim

**Modify HID output**:
1. Edit `src/hid.c` for report generation logic
2. Check `include/zmk/hid.h` for HID report structures
3. Test with both USB and BLE endpoints in `core-coverage.yml`

**Fix split keyboard issue**:
1. Identify if central or peripheral: Check `CONFIG_ZMK_SPLIT_ROLE_CENTRAL` in logs
2. Central logic: `src/split/central.c` (receives matrix events, sends to peripheral)
3. Peripheral logic: `src/split/peripheral.c` (scans matrix, sends to central)
4. BLE communication: `src/split/bluetooth/` (includes pairing, disconnection handlers)
5. Test with `run-ble-test.sh tests/ble/split` if applicable

**Debug build failure**:
1. Check `build/*/build.log` (CMake/compiler errors)
2. Check `Kconfig` defaults for conflicting options
3. Use `-DCONFIG_ZMK_LOG_LEVEL=4` for debug logging
4. Rebuild with `west build -d build/test -p` (pristine) if cached issues persist

## Key Files to Know

- **`src/keymap.c`**: Parses keymap from device tree, resolves behaviors at runtime
- **`src/hid.c`**: HID report generation (separate codepaths for HKRO vs NKRO)
- **`src/ble.c`** & **`src/usb.c`**: BLE and USB endpoint implementations
- **`include/drivers/behavior.h`**: Behavior driver API, syscall definitions
- **`include/zmk/event_manager.h`**: Event system macros
- **`dts/bindings/`**: YAML schema definitions for all configurable components
- **`boards/*/Kconfig`**: Board-specific configuration and defaults

## References

- Zephyr documentation: https://docs.zephyrproject.io/
- ZMK documentation: https://zmk.dev/docs/
- Behavior development: Study `src/behaviors/behavior_hold_tap.c` for complex state machine example
- Event flow: Trace a keypress through `matrix_transform.c` → `position_state_changed` → `keymap.c` → behavior invocation → HID output
