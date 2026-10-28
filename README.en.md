# Claude Desktop — Chinese UI for 3rd-party / Gateway mode (macOS)

Make **Claude Desktop** display a Chinese UI when it's pointed at a **third-party API relay**
(CC Switch → Gateway / "3p" mode), where the account-based language setting is unavailable.

> Tested on macOS · Claude Desktop **3.6556.2** and **4.29.0** · Apple Silicon
> 中文说明见 [README.md](README.md)

> **Claude 4.29+ note**: the front-end moved from `Resources/ion-dist/` (a directory) to
> `Resources/ion-dist.asar` (a 191 MB archive) and now enforces asar integrity. The scripts
> detect the layout automatically: asar mode extracts → patches → repacks, disables the
> `EnableEmbeddedAsarIntegrityValidation` fuse, then re-signs with `--deep`.
> Details: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) §10.

---

## The problem

Claude Desktop resolves its UI language in two steps:

- **Signed in to claude.ai** → uses the account locale → you can pick Chinese, works fine.
- **Relayed through a third-party endpoint** → no claude.ai session, so it falls back to
  `navigator.language` → English, with **no way to change it in Settings**.

It's not that your language preference was lost. It's that **the app ships no Chinese pack at all**:

```
/Applications/Claude.app/Contents/Resources/ion-dist/i18n/dynamic/
  de-DE  en-US  es-419  es-ES  fr-FR  hi-IN  id-ID  it-IT  ja-JP  ko-KR  pt-BR
  ↑ 11 locales, no Chinese
```

The full pack is normally fetched at runtime from `https://claude.ai/i18n/zh-Hans.json`.
Signed in, that works. Behind a relay there is no session, the fetch never happens,
and the UI stays English.

This repo **installs a Chinese pack on disk and patches the frontend's language whitelist
and default locale**, so the UI no longer depends on the network or an account.

---

## What gets changed

```
① pack files     ion-dist/i18n/zh-Hans.json + zh-CN.json (alias)
                 ion-dist/i18n/dynamic/zh-Hans.json + zh-CN.json
② whitelist      append "zh-Hans","zh-CN" to the locale array in assets/v1/shared-*.js
③ default locale var ry="zh-Hans" / var yy="zh-Hans" (was "en-US")
④ re-sign        ad-hoc, WITH --entitlements (dropping it breaks the workspace VM)
```

### Why two aliases (`zh-Hans` + `zh-CN`)

The frontend matches locale names **exactly — there is no prefix fallback**, and the
`--lang` flag handed to the renderer is derived from the system locale:

| System `AppleLanguages` | Renderer `--lang` | Whitelist with only `zh-Hans` |
|---|---|---|
| `zh-Hans` | `zh-Hans` | match ✅ |
| `zh-Hans-US` (Simplified Chinese + US region — very common) | **`zh-CN`** | **no match → entire UI in English** ❌ |

This is the #1 reason tutorials fail after moving to another machine. Details in
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

---

## Quick start

Requirements: macOS, Claude Desktop, `python3`, `node`. **No `sudo` needed** if the app is
owned by you (`ls -ld /Applications/Claude.app`).

```bash
git clone https://github.com/anong8090/claude-desktop-zh-hans.git
cd claude-desktop-zh-hans

# 1) extract the official Chinese pack from the local Chromium cache (offline, ~3s)
./scripts/extract-zh-pack.sh

# 2) install: pack + whitelist + default locale + re-sign
./scripts/reinject.sh --restart

# 3) verify
./scripts/verify.sh
```

Preview without writing anything:

```bash
./scripts/reinject.sh --dry-run
```

### Why the pack comes from the cache

`https://claude.ai/i18n/zh-Hans.json` is Cloudflare-protected — `curl` gets **403**
regardless of User-Agent. But once you've used the Chinese UI while signed in, the app has
already cached that pack at:

```
~/Library/Application Support/Claude/Cache/Cache_Data/<hash>_0
```

`extract-zh-pack.sh` parses that Chromium simple-cache entry (24-byte header + key +
brotli body) and decompresses it. Fully offline, no login, no proxy.

---

## Docs

| File | Content |
|---|---|
| [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) | How the frontend resolves locale, cache format, version adaptation, ICU placeholder validation |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Still English / workspace `installation invalid` / app won't launch / false-positive checks |
| [docs/FREE-TOKENS.md](docs/FREE-TOKENS.md) | Free API sources (AMD, NVIDIA NIM, …) + CC Switch setup |
| [packs/README.md](packs/README.md) | Why the language pack is not in this repo, and how to obtain it |

---

## Verification matters

`./scripts/verify.sh` checks six things (the extra two are asar-integrity fuse state and leftover
misconfigurations). Item 2 is the one most tutorials get wrong:
when Claude isn't running you can't read `--lang`, and `grep -q ""` is **always true** —
so a broken setup reports OK. This script prints `SKIP` instead of `PASS` in that case.

```
1) pack files present (zh-Hans + zh-CN, static + dynamic)
2) whitelist contains the *actual* runtime --lang value
3) codesign --verify passes
4) com.apple.security.virtualization entitlement still present
```

---

## Known limitations

- Only the **UI** is translated. Model output language is a separate thing (prompt-level).
- ~417 strings stay English on 3.6556.2 because the official pack leaves them untranslated
  (`Artifacts`, `Cowork`, `Code` — product names) or because they're hardcoded in the JS bundle.
- Claude updates overwrite `ion-dist/`. Re-run `./scripts/reinject.sh --restart` after each update.
- No Windows / Linux support (paths and signing are macOS-specific).

---

## Disclaimer

- Not affiliated with, endorsed by, or sponsored by Anthropic.
- Modifying the app bundle breaks its official code signature (replaced with an ad-hoc one).
  Evaluate the consequences yourself.
- For personal use on a copy of Claude Desktop you legitimately obtained. Whether this
  complies with the service terms is your call.
- The language pack content is Anthropic's; this repo neither contains nor distributes it.

## License

Scripts and docs: [MIT](LICENSE). Language pack content: not applicable (not included).
