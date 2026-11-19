# Firmware version advisories and catalog maintenance

The release catalog answers a deliberately narrow question: **what main
firmware version is announced on the selected official GuliKit release page?**
It does not discover attached models, infer compatibility, download firmware,
change pinned package/BIN hashes, or authorize an installation.

## Initial scope

The bundled catalog initially covers main firmware for four model families:
`NS58`, `NS59`, `NS39`, and `NS38`. Each entry keeps its official page, component
label, announced version, and bundled-review timestamp together. Entries do not
combine main firmware with Bluetooth, receiver, or other separately versioned
components.

| Entry | Model | Bundled main-version snapshot | Official page for manual review |
| --- | --- | --- | --- |
| `ns58-main` | Elves 2 / NS58 | 3.7 | [Elves 2 firmware](https://www.gulikit.com/newsinfo/1071651.html) |
| `ns59-main` | Elves 2 Pro / NS59 | 5.8 | [Elves 2 Pro firmware](https://www.gulikit.com/newsinfo/1050198.html) |
| `ns39-main` | KK3 Max / NS39 | 5.9 | [KK3 firmware](https://www.gulikit.com/newsinfo/887152.html) |
| `ns38-main` | KK3 Pro / NS38 | 5.8 | [KK3 firmware](https://www.gulikit.com/newsinfo/887152.html) |

These are bundled advisory values, not a promise that the website is still
current. NS39 and NS38 deliberately use separate entries despite sharing a
page: an NS39-only heading must not advance NS38. The parser selects the first
explicit matching model/component release heading rather than taking the
largest number found anywhere in the page or changelog.

Only the validated **NS58 / Elves 2** USB update path is supported by the updater.
Having a release-catalog entry for another model does not add USB-write support
for it. The supported NS58 V3.7 installer and its pinned hashes remain a
separate reviewed capability, even if an official page later announces a newer
version.

For NS58, a readable installed version from the FAT root volume label can be
compared with a fresh announced version for an advisory. An older but otherwise
recognizable label may be reported as older without making that controller or
its filesystem eligible for the current fixed, validated write plan. Unknown
or stale catalog information must not become a claim that the controller is
up to date.

## App workflow

The main window's **Firmware Versions & Official Downloads…** button opens the
separate advisory window. Its model picker does not change USB matching or
installation support. The app requests an automatic metadata check on launch;
opening/reopening the catalog also consults the cache and backoff. **Check All
Models Now** skips the success interval but not failed-attempt backoff. Visible
advice is re-evaluated against the clock every minute and on presentation, so
a retained result cannot stay current after its 24-hour window.

**Open Official Firmware Page** opens only a bundled official URL in the normal
browser. Complete any download verification there, extract the firmware, and
use the main window's local BIN chooser. This change does not add ZIP import or
automate firmware downloads. The existing mirror action is now explicitly
labeled optional and third-party.

Read-only NS58 inspection keeps its existing device/transport/capacity gates,
then reads the FAT12 root label separately from the strict writer validator.
It can retain an older or unknown readable label without quarantining a
healthy USB session merely because its version is not 3.7. A successfully read
but unsupported baseline gets a separate installation-block reason. Every
Install gate requires strict baseline validation, and the original update
planner revalidates the baseline immediately before the unchanged writes.
Transport/ownership failures still use the existing fresh-session recovery
gates. The catalog compares an observed NS58 version only after the person
confirms the physical NS58 label; it does not pretend a version label proves
the model.

## CLI: offline unless explicitly refreshed

```sh
swift run gulikit releases
swift run gulikit releases --json
```

The running CLI uses the bundled snapshot only, without opening USB devices,
requesting official release pages, or reading a persistent advisory cache. The
output labels the source/status as bundled and preserves the bundled-review
date. This is
useful offline, but is not proof of today's latest release. `swift run` may
still need the project's ordinary build dependencies if they are not cached;
the compiled `gulikit releases` executable itself requires no network access.

An explicit refresh requests bounded official HTML pages:

```sh
swift run gulikit releases --refresh
swift run gulikit releases --refresh --json
```

Requests are handled by `FirmwareCatalogService`; no firmware ZIP/BIN is
downloaded and no device is opened. The CLI checks each catalog entry once,
sequentially, and performs no automatic HTTP retry. The service's failure
handling and backoff still apply. A new CLI process uses an in-memory service,
so repeated CLI invocations are not a substitute for respecting a site's
rate limit; do not run this command in a tight loop.

## Source, timestamps, cache, and failures

The service distinguishes **live**, **cache**, and **bundled** sources, plus
**fresh**, **stale**, **refreshFailed**, and **bundled** statuses. A successful
runtime result has a 24-hour freshness window; failed attempts are subject to
a five-minute backoff, including forced requests within the same service/cache
history. Cache state is advisory only and must not affect the installer pins.
`bundledReviewedAt` is not a live `checkedAt` date.

If the official page is unavailable, blocked, rate-limited, or no longer has a
clearly associated version, show the failure and source instead of silently
treating the bundled or stale value as a current check. The ordinary app/build
must continue to work without network access. If a page requires browser
verification or CAPTCHA, open the entry's `sourceURL` manually in a browser.
Do not try to bypass the challenge or repeatedly refetch it. Manual browsing
also permits reviewing changelog/model/component context that a narrow title
parser deliberately does not interpret as installation approval.

The JSON output is an array with one record per entry. Each record includes:

- `id`, `displayName`, `modelCodes`, and `componentLabel`;
- `version` (nullable), `bundledVersion`, and the official `sourceURL`;
- `checkedAt` (nullable) and `bundledReviewedAt`, encoded as ISO 8601;
- `status`, `source`, `failure` (nullable), and `allowsCurrentComparison`.

Nullable keys remain present as JSON `null`, so review tooling can distinguish
missing current evidence from a successful check. After `--refresh`, the CLI
still emits every record, including successful entries if another fails, then
exits **1** if any refresh has a failure or cannot establish a current
comparison. It reports that incomplete result on stderr. Successful complete
refreshes exit **0**. Offline bundled output exits **0**, without asserting a
current comparison.

## Explicit maintainer check

```sh
./scripts/check-firmware-catalog.sh
```

This is a build-and-check convenience for a maintainer or explicitly scheduled
CI job. It executes `swift run gulikit releases --refresh --json`, passing
through its exit status. SwiftPM build diagnostics go to stderr; advisory JSON
goes to stdout. It is **not** wired into normal builds or tests, so a website
failure cannot make ordinary development depend on the website.

Review the output and official page manually before changing catalog data.
Do not automatically rewrite catalog versions, update installer hashes, add
models to USB matching, or enable a new firmware image based on a successful
HTML check. Those are separate reviewed changes with their own file identity,
compatibility, and hardware-verification requirements.

## Implementation validation — November 18, 2026

- Signed Debug app build and strict bundle signature verification passed in a
  separate local DerivedData directory. The app was **not launched**; GUI
  layout, sandboxed runtime network behavior, and physical USB inspection were
  not hardware/UI-tested during this change.
- Full `swift test` with the existing local BIN and Linux root-directory
  fixtures completed: **114 passed, one skipped**. The skipped test needs the
  pinned ZIP archive fixture. This includes 16 catalog tests, 18 version-probe
  tests, the explicit strict-baseline installation gate, and the existing
  capture-derived two-write plan regression. Parameterized cases are additional
  coverage within those reported test counts.
- Offline `gulikit releases --json` returned four records with bundled source,
  no successful-live-check timestamp, and current-comparison permission false.
  Repeated options were rejected before any network operation.
- One live CLI metadata-check batch could not obtain explicit usable model
  headings. It retained the bundled observations, returned `refreshFailed`,
  kept current-comparison permission false, and exited 1. Separate direct
  diagnostic requests also received HTTP 429. A live successful version check
  is **not established** by this run; no challenge was bypassed and no repeated
  success-seeking batch was run.
- Later parser/failure-isolation changes were verified offline rather than
  issuing another live batch. Tests cover stale/future observations, the exact
  24-hour boundary, per-model failures on a shared page, model-coded shell
  titles, and BT/CPU/dongle headings.
- Original `NS58Core.swift`, firmware hashes, allocation/write-plan logic,
  USBTransport implementation, and two write commands were left unchanged.
  No firmware payload was downloaded, no controller was claimed or reset, and
  no firmware write or flash-drive comparison was performed.

## Catalog window and browser validation — November 19, 2026

- The original signed build's catalog button ran the background check but did
  not show a window. Its programmatic controller used `NSWindowController(window: nil)`,
  so `showWindow` had no nib or window to load. The repaired controller creates
  the window on first presentation, then reuses it.
- In the rebuilt signed app, the button opened the catalog and the model picker
  showed all four entries. **Open Official Firmware Page** was exercised
  separately for NS58, NS59, NS39, and NS38. Chrome loaded the expected release
  page each time: `1071651.html`, `1050198.html`, `887152.html`, and
  `887152.html`, respectively. The shared page's body distinguishes Max V5.9
  from the V5.8 release listed for Pro.
- Browser page loading is not an automatic metadata refresh. The app still
  showed bundled data with no successful live check. The metadata checker,
  firmware pins, and controller logic were not changed; no firmware was
  downloaded and no controller was tested.
