# LeadYa installer

Windows LOCAL installer sources and build/release tooling for LeadYa, licensed under Apache-2.0.
The application downloaded by the installer is a separate product with its own license.
This repository contains no private application history, signing keys or customer data.

A successful source build is not a signed release or an antivirus clearance. See [SECURITY.md](SECURITY.md) and
the dependency/license limitations in [DEPENDENCIES.md](DEPENDENCIES.md).

## Code signing policy

SignPath Foundation approval and signing setup are pending; the project is not yet
approved and CI packages remain unsigned assessment builds. Read the
[code signing policy and installer privacy information](CODE_SIGNING_POLICY.md).
The separately licensed LeadYa application is outside this signing request.

## Build

Public [Windows CI builds](https://github.com/tomaszzygadlo/leadya-installer/actions/workflows/build.yml)
include the installer, its checksum and build provenance. These are unsigned assessment
artifacts, not Foundation-approved releases; artifact downloads require a GitHub login.

Install the dependencies described in [DEPENDENCIES.md](DEPENDENCIES.md), then run:

```sh
mvn clean verify
```

The default artifact is `target/LeadyaInstaller.exe`, configured for the hotfix public
origin. Build output and `.build.json` always start with `publication_ready=false`.
To select a compiler or a backend, quote Maven properties in PowerShell:

```powershell
mvn clean verify '-Dinstaller.compiler=C:/tools/NSIS/makensis.exe' '-Dinstaller.backend=https://backend.example.test' '-Dinstaller.origin=https://example.test'
```

The direct Python entry point is also available:

```sh
python build.py --output target/LeadyaInstaller.exe --plugin-directory /path/to/unicode-plugins
```

## Integration with LeadYa Maven

LeadYa retains its existing `ExternalInstaller/BuildInstallers.ps1` and `.sh` entry points
and installer history. Its Maven lifecycle continues to call those adapters. The intended
integration uses a reviewed snapshot pinned to an exact public commit and a SHA-256 source
inventory; a normal build verifies local sources without fetching a moving `main` branch.
The private domain/variant configuration and separate VPS provisioning installer remain in LeadYa.
The shared renderer supports `--render-script` for those adapters; it preserves the
functional template body and changes only four declared variant values. Public builds
require HTTPS. `--allow-loopback-http` explicitly enables HTTP for localhost and loopback
IP addresses in local development; it never enables plain HTTP to external servers.

## Source layout and application data

The first complete source version is imported in one commit. `installer-inputs.json`
maps the root-level source files to the historical NSIS `Language/` and `Docs/` layout
inside a temporary build directory. No manual file rearrangement is needed.
The `license_*.txt` files describe the separately licensed application; they are not
the license of this installer project. NSIS includes and plugins keep upstream licenses.

Program files default to Program Files. A protected seed, launcher and uninstaller live
in `Program Files\LeadYaInstallerPackages\<installation hash>`, writable only by
administrators and SYSTEM. A custom code directory contains a copy; elevated validation
uses the protected seed under a read lock, and shortcuts target the protected launcher.
The installer does not broaden permissions on ancestors of the chosen directory.
An administrator-controlled copy is published atomically. Copies in ordinary writable
directories, all private runtime writes and Chromium provisioning happen under the
ordinary user's token. The launcher refuses an elevated fallback from ShellExecAsUser.
Writable runtime data, bot files, browser profiles and caches use a private per-user
directory derived from the installation path and origin, with a private profile fallback
if AppData permissions are unsuitable.
The launcher prepares that directory for the actual Windows user, including after
installation with another administrator account. Before completion, the installer checks
the protected payload, JRE and the application's actual read-only installation policy.
The first ordinary launch prepares the runtime and checks its complete policy again.
Existing installation data is retained.

Windows file metadata uses the four-part version in `installer-version.txt`, or the
explicit `--installer-version` argument. This is independent of the Maven module version.
When the template pins the validator's SHA-256, the builder checks the helper's exact
bytes before compilation. Preserve the byte-preserving Git attributes: changing only
the helper's line endings also changes its runtime integrity pin and must fail the build.

## Tests and release

```sh
python -m unittest -v test_build
```

Windows release-policy tests use synthetic signatures and scanner processes; the native
process probe checks real exit codes without running an installer. Neither test is an AV scan.
Use the release helper on an independent clean Windows signing/scan host for real evidence.
Preserve application data outside the code directory, and never broaden ancestor ACLs to
make a destination pass validation. Product installers must be tested with default and
custom paths and an ordinary Windows user before publication.

## Local uninstall choices

The uninstaller removes its validated program/package, including retained JARs and
installer logs. Two independent default-on choices can retain the user's marked
profile or recognized LeadYa EXE/VPS ZIP downloads. Java removal stays separately
opt-in. Other downloads and unrelated program-directory files are retained. Close
LeadYa and its browsers before deleting the profile. A locked file, foreign marker
or junction refuses cleanup before removing program files; interrupted deletion can
be retried. Private data is removed only by the desktop user's ordinary token, with
an exact live owner identity and a 90-second deadline set before dispatch.

`Test-LocalUninstallCleanup.ps1 -NsisCompiler <supported makensis.exe>` tests deletion
and preservation with disposable native fixtures. The separate
`Test-LocalUninstallTransport.ps1 -Compiler <supported makensis.exe>` requires normal
UAC consent and tests the actual admin callback with uniquely owned disposable data.
It redirects only the Downloads boundary; it never deletes real downloaded installers.