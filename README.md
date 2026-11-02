# Scoop Controlled

A controlled [Scoop](https://scoop.sh/) aggregator bucket. It gathers manifests from a number of upstream Scoop buckets into one place, and acts as a firebreak between those upstream buckets and the machines that install from this one: upstream changes are tracked, delayed and checked before they are taken on, rather than flowing straight through.

Every manifest records where it came from. The maintenance scripts compare each one with its upstream copy and apply routine version updates automatically. Changes that need a decision are held back for review: a new download domain or GitHub repository, a licence change, a version going backwards, or structural changes to the manifest.

Installers can optionally be mirrored into an artifact repository (e.g. Nexus), so that installs don't depend on the original download sites. See [Mirroring installers](#mirroring-installers).

## Usage

After installing [Scoop](https://scoop.sh/), add this bucket from a Command Prompt or PowerShell window:

```powershell
scoop bucket add scoop-controlled https://github.com/wiry-dev/scoop-controlled
```

Then install any app from it, for example:

```powershell
# Don't include the .json file extension in the app name
scoop install scoop-controlled/freeorion
```

## How it works

| Piece | Purpose |
|---|---|
| `bucket/` | The manifests. Each carries tracking metadata in its `##` comment block (see [Metadata](#metadata)). |
| `local-repos.cfg` | The upstream buckets tracked, as local clone paths and git remotes. |
| `Update-Bucket.ps1` | Compares manifests with their upstream copies, applies simple updates and locks or holds back the rest. Run it periodically. |
| `Add-Manifest.ps1` | Copies a manifest from a local upstream clone into `bucket/` with its metadata filled in. |
| `Seed-ManifestSources.ps1` | Finds and records the upstream source of existing manifests; also has one-off repair and migration modes. |
| `ManifestMetadata.ps1` | Settings shared by the scripts above: the metadata prefix, the metadata keys and the sources root variable. |
| `scripts/update-installers.sh`, `scripts/migrate-installers.sh` | Optional mirroring of installers into an artifact repository. |

## Setting up

The scripts work against local clones of the upstream buckets, which are faster to read than the web and allow the git history to be checked.

1. Choose a folder for the upstream clones and set the `SCOOP_CONTROLLED_SOURCES` environment variable to it:

   ```powershell
   [Environment]::SetEnvironmentVariable('SCOOP_CONTROLLED_SOURCES', 'D:\src\scoop-sources', 'User')
   ```

2. Clone the upstream buckets listed in `local-repos.cfg` and bring them up to date. Any that are missing are cloned under the folder names the file gives them:

   ```powershell
   .\Update-Bucket.ps1 -PullSources
   ```

The scripts stop with an error if `SCOOP_CONTROLLED_SOURCES` isn't set, rather than treating every manifest as having lost its upstream.

### Local sources

Local paths are only meaningful on one machine, so nothing machine-specific is stored. Instead:

- `local-repos.cfg` lists each upstream as `%SCOOP_CONTROLLED_SOURCES%\<folder>;<git remote>`. The folder names are fixed here, and `-PullSources` clones to them, so every machine ends up with the same layout under its own root.
- Each manifest's `__source` is stored relative to the same root, e.g. `%SCOOP_CONTROLLED_SOURCES%\scoop-extras\bucket\age.json`. It is expanded when read, and paths under the root are turned back into this form when written.
- `__sourceUrl` (the raw upstream URL) identifies the upstream independently of any local layout.

## Adding applications

To add an application, copy its manifest from one of the upstream clones with `Add-Manifest.ps1`, which also fills in the tracking metadata:

```powershell
# Finds age.json in whichever upstream clone has it
.\Add-Manifest.ps1 -TargetManifestName age
```

Manifests can also be written by hand in the `bucket` directory; see the [Scoop Wiki](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) for the manifest format. `Seed-ManifestSources.ps1` can then find and record their upstream source. Manifests with no upstream are marked `manual` and are maintained by hand.

## Keeping manifests up to date

`Update-Bucket.ps1` is meant to be run periodically and needs no arguments for a normal run:

```powershell
# Pull the upstream clones, then apply updates
.\Update-Bucket.ps1 -PullSources
```

For each manifest it compares the local copy with the upstream copy:

- **Simple changes** (only version, URLs, hashes and `extract_dir`) are applied automatically, once the upstream change is older than the delay period (default 7 days) and the manifest hasn't been updated within the minimum period (default 2 days).
- **Complex changes** (anything else in the manifest) are reported with a diff and left for review, unless `-AutoComplex` is given.
- **Concerns** lock the manifest until it is reviewed:

  | Lock | Raised when |
  |---|---|
  | `domain-change-lock` | The set of download/homepage domains changes, or a GitHub URL points at a different account or repository. GitHub's own hosts (`api.github.com`, `raw.githubusercontent.com`, ...) and the GitHub Pages site (`{owner}.github.io`) of an owner already in use count as GitHub. |
  | `license-change-lock` | The licence changes, unless it moves from one open licence to another (see `sourceLicenceOpen`). |
  | `version-check-lock` | The upstream version is lower than the local one (compared numerically, so 5.10 is newer than 5.9), or newly adds an alpha/beta marker. |
  | `missing-source-lock` | The upstream manifest can no longer be found (and isn't in the upstream's `deprecated` folder). |

  A normal run releases a domain, licence or version lock by itself once its condition no longer applies.

### Modes

| Command | What it does |
|---|---|
| `.\Update-Bucket.ps1` | Normal run: applies simple updates, locks concerns, reports complex changes. |
| `-PullSources` | Clone any missing upstream and pull them all first (combines with the other modes). |
| `-Interactive` | Steps through each pending change, prompting to accept, freeze or skip. |
| `-ProcessLocks` | Steps through locked and frozen manifests, prompting to accept (and unlock), freeze or skip. `-ExcludeFrozen` leaves frozen ones out. |
| `-ListPending` / `-ListLocks` / `-ListManual` | Lists manifests with pending changes, with locks, or maintained by hand. |
| `-FullUpdate` | Ignores the delay and minimum periods, compares every field, and applies complex changes; locked and manual manifests are still left alone. |
| `-NormaliseMetadata` | Rewrites metadata into the current form (prefix, relative `__source`) and sets `sourceLicenceOpen`. |
| `-Scope '<regex>'` | Limits any mode to manifests whose name matches. |

Prompts show what pressing Enter will do:

| Situation | Default |
|---|---|
| Domain or version lock, or a complex change | Accept |
| Frozen manifest | Skip (it stays frozen) |
| Any licence concern | Freeze, then prompt for a comment |

In `-ProcessLocks`, **D**isplay shows the current manifest and the diff, then asks again about the same manifest.

## Metadata

Scoop's manifest schema only allows extra information in the `##` comment property (a string or array of strings), so the tracking data is kept there, one `key: value` line per entry. Each line starts with a prefix, `__` by default, set by `$MetadataPrefix` in `ManifestMetadata.ps1`. The prefix keeps these lines distinct from any upstream comments in the same block; ours are always written after those. Lines without the prefix (the older format) are still read, and `-NormaliseMetadata` rewrites them.

| Key | Meaning |
|---|---|
| `source` | Path of the upstream manifest in its local clone, relative to `%SCOOP_CONTROLLED_SOURCES%`. `MANUAL` if there is no upstream. |
| `sourceUrl` | Web location of the upstream manifest, typically its raw file on GitHub. |
| `sourceState` | `active` (tracked), `manual` (no upstream; maintained by hand), `frozen` (held at its current version until a deliberate decision), `dead` (ignored), `deprecated` (upstream moved it to `deprecated`), or one of the locks above. |
| `sourceLastUpdated` | When the upstream manifest last changed. |
| `sourceLastChangeFound` | When a run last found and recorded a change. |
| `sourceHash` | Hash of the upstream file at the last update. Used to detect changes without reading git history, which can be very slow for old files in large repositories. |
| `sourceLicenceOpen` | `true` for open licences (Apache, MIT, GPL/LGPL/AGPL, Eclipse or BSD), otherwise `false`. Where several licences all apply (comma-separated), all must be open; where there is a choice (`\|`), one is enough. Maintained by the scripts. |
| `sourceDelayDays` | *Optional.* Days to wait after an upstream change before applying it (overrides the default). |
| `sourceUpdateMinimumDays` | *Optional.* Minimum days between applied updates (overrides the default). |
| `sourceDeferredUpdateFound` | Set when an update was found but deferred, e.g. by the delay period. |
| `sourceComment` | *Optional.* Free text, mostly explaining why a manifest is frozen. |
| `sourceNotes` | *Optional.* Free-text notes. |

### Example

The metadata of `bitwarden.json`, which comes from [Scoop Extras](https://github.com/ScoopInstaller/Extras):

```json
  "##": [
    "__source: %SCOOP_CONTROLLED_SOURCES%\\scoop-extras\\bucket\\bitwarden.json",
    "__sourceHash: 8a55111ed3b27930d29947bdb445723d3c397e2d",
    "__sourceLastChangeFound: 260128 15:32:50",
    "__sourceLastUpdated: 260113 20:30:03",
    "__sourceLicenceOpen: true",
    "__sourceState: active",
    "__sourceUrl: https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/bitwarden.json"
  ]
```

## Mirroring installers

`scripts/update-installers.sh` brings manifests up to the upstream versions and then runs `scripts/migrate-installers.sh`, which uploads each installer to an artifact repository with Maven and points the manifest at the uploaded copy. Both read the same settings. Each can be given as a command-line option (`--REPO_URL=https://repo.example.org`) or an environment variable of the same name, in that order of precedence. Anything not given falls back to a placeholder that won't work until replaced, and the scripts warn when placeholders are in use.

| Setting | Default |
|---|---|
| `REPO_URL` | `https://repo.example.com` (placeholder) |
| `REPO_ID` | `thirdparty` |
| `REPO_GROUP_ID` | `scoop` |
| `REPO_UPLOAD_URL` | `$REPO_URL/content/repositories/$REPO_ID` |
| `REPO_DOWNLOAD_URL` | `$REPO_URL/repository/$REPO_ID` |
| `REPO_MIRROR_URL` | `$REPO_URL/repository/mirror` |
| `REPO_USERNAME` | `uploader` (placeholder) |
| `REPO_PASSWORD` | placeholder; or set `REPO_PASSWORD_COMMAND` to a command that prints it, e.g. `pass show repo/uploader` |
| `MAVEN_SETTINGS_TEMPLATE` | `files/settings.xml` |

`files/settings.xml` is a template: its `@@NAME@@` tokens are filled from these settings into a temporary `local/settings.xml`, so no hosts or credentials are kept in the repository.

## Licence

Files in this repository are dedicated to the public domain under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/); see [LICENSE.md](LICENSE.md). The applications the manifests install have their own licences, given in each manifest's `license` field.

## Buckets to review

There are a great many Scoop buckets, some with thousands of applications. Full coverage isn't the aim, but applications in regular use should be brought in here, and other buckets are worth reviewing periodically: they may already have solved auto-updating for an application, and they help with discovering new tools.

Many buckets serve purposes such as proxy evasion, translated builds or particular licence restrictions, so be careful what is taken from them: always inspect the manifest and the source of its executables.

- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Fzzhaq%2Fscoop-av%22&o=false> - many executable and decompilation tools
- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Frizwan-r-r%2Fredesigned-fiesta%22&o=false> - development tools

## Disclaimer

No warranty or guarantee of any nature is provided or implied. No liability will be incurred for use of any material in this repository. Use at your own risk. Scoop inherently trusts the sources of the manifests and their contents; ensure you validate these before use. Be aware that versions may change and software may become unsupported or insecure over time, both maliciously and accidentally.
