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

The installer never asks for administrator rights (`RequestExecutionLevel user`) and
writes only into the folders of the Windows user who runs it:

| What | Where |
| --- | --- |
| Program files (another folder can be chosen) | `%LOCALAPPDATA%\Programs\Leadya` |
| Package: launcher, validator, uninstaller, seed | `%LOCALAPPDATA%\LeadYa\packages\<id>` |
| Java runtime | `%LOCALAPPDATA%\LeadYa\Java\jdk-17.0.21+9-jre` |
| Profile, configuration, downloaded updates | `%LOCALAPPDATA%\LeadYa\installations\<id>` |
| Apps & features entry | `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Leadya` |
| Shortcuts | personal Start menu, desktop and startup folder |

`<id>` is the SHA-256 of the program path and the public origin. If the profile location
does not pass the private-profile checks, `%USERPROFILE%\.leadya-client\installations\<id>`
is used. No machine-wide `LEADYA_HOME` is written; the launcher sets it for its own process.

The folder page stays. Instead of reading permissions, the installer creates and removes a
probe file in the chosen folder (or in its nearest existing parent). A folder the user cannot
write, such as Program Files, is refused with `LOCAL_ADMIN_REQUIRED` and the page is shown
again; the installer never retries with elevation. The installer does not change permissions
of the chosen folder or its ancestors and refuses links and junctions. The validator and the
launcher refuse an elevated token, so an installer started "as administrator" stops with a
plain message.

The Java archive is downloaded from the selected backend and must match the SHA-256 pinned in
the validator before it is unpacked into a staging folder and published with one rename.
Before completion, the installer checks the package, the JRE and the application's actual
installation policy. The first ordinary launch prepares the runtime and checks its complete
policy again. Existing installation data is retained.

Computers installed earlier into `Program Files\Leadya` are adopted without moving anything:
the `Adopt` validator mode checks the old package like the uninstaller does and requires the
marker in the profile of this same Windows user; the old program path stays the identity that
derives `<id>`, so the new package finds the old profile. Before anything is published, the
`AdoptGuard` mode places a hard-linked guard pair in that profile, which makes the old
uninstaller's profile cleanup refuse before it deletes anything. The old shared Java in
`Program Files\Java\jdk-17.0.9+9-jre` is kept as an emergency fallback. The launcher picks
the per-user Java first, then the shared folders under `ProgramW6432` and `ProgramFiles`, and a
per-user Java marked as refused only as the last resort.

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
be retried. The uninstaller runs with the same ordinary token as the installer and
removes only the folders of that user. An uninstall that keeps the profile also keeps
the saved identity, so a later install finds the same profile.

`Test-LocalUninstallCleanup.ps1 -NsisCompiler <supported makensis.exe>` tests deletion
and preservation with disposable native fixtures. The separate
`Test-LocalUninstallTransport.ps1 -Compiler <supported makensis.exe> -PluginDirectory <plugins>`
runs the actual user cleanup callback with uniquely owned disposable data and no elevation.
It redirects only the Downloads boundary; it never deletes real downloaded installers.
`Test-LocalJavaSelection.ps1` checks the launcher's Java order, including a refused runtime.
