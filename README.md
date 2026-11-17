# MenuStats

Compact system stats in the macOS menu bar, with a BatFi-style panel when you click it.

- **Menu bar:** CPU, memory, GPU, disk, network, CPU temperature and power, in Classic, Pills or Rings style.
- **Overview:** per-core CPU, GPU clock and power, Neural Engine, memory pressure and bandwidth, per-interface network details, Wi‑Fi details, speed test, disk, temperatures and fans.
- **Processes:** top apps by CPU, memory, energy, network and disk (grouped by app), listening ports, process search, frozen-app detection, Docker containers and a "force quit all apps" button.
- **Cleanup:** Trash, caches, logs, Downloads, developer caches, Docker, unused apps, a System Data breakdown and a space map.
- **Alerts:** the menu bar turns red when CPU, memory pressure or free disk space need attention.

Requires macOS 14 (Sonoma) or later. Runs on Apple silicon and Intel; some stats (GPU clock, Neural Engine, power) are Apple silicon only.

## Install

```bash
brew tap stephanevdb/menustats https://github.com/stephanevdb/menustats
brew trust stephanevdb/menustats
brew install --cask menustats
```

`brew trust` is needed once on recent Homebrew versions, which only load casks from taps you've approved.

MenuStats is self-signed rather than notarized by Apple; the Homebrew cask clears the download quarantine so it opens normally.

## Build from source

```bash
./build.sh --install
```

Needs Xcode 16 or later. `./release.sh <version>` builds a universal zip for a GitHub release and updates `Casks/menustats.rb`.

## License

MIT
