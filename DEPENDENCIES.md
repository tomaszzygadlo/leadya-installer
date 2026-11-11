# Build dependencies

The [Windows CI workflow](.github/workflows/build.yml) prepares the exact official
archives and Unicode DLLs pinned in [ci-dependencies.json](ci-dependencies.json).
It extracts the NSIS setup archive with the runner's 7-Zip without executing setup.
`ci_bootstrap.py` verifies archive, compiler and DLL SHA-256 values before compilation;
it never installs system software or changes antivirus settings. Local builds may
continue to provide their own compatible compiler/plugins as described below.

- Python 3.9 or later, standard library only.
- Maven 3.6.3 or later for the optional Maven entry point (3.9 is recommended).
- Stable NSIS 3.13 or later from https://nsis.sourceforge.io/Download.
  NSIS licenses: https://nsis.sourceforge.io/License.
- Unicode NSIS plugins supplied separately in a `plugins` directory, or selected with
  `--plugin-directory`: INetC.dll, nsisunz.dll.

Official plugin sources and release archives:

| Component | Source | License evidence |
|---|---|---|
| INetC | https://nsis.sourceforge.io/Inetc_plug-in | NSIS project notices; preserve the complete upstream archive and notices |
| nsisunz Unicode | https://nsis.sourceforge.io/Nsisunz_plug-in | zlib-style notice in the distribution readme; bundled zlib notices also apply |

No plugin DLL, NSIS SDK, Java runtime or application binary is redistributed by this source
repository. Supply dependencies whose use and distribution you are authorized to perform.
Do not label these components as first-party Apache code.

Earlier versions also used the AccessControl and ShellExecAsUser plugins to run as
administrator and hand work back to the desktop user. The installer now runs with the
ordinary user's token only, so neither plugin is needed and the build stages only INetC and nsisunz.

The installer currently downloads the separately licensed application/runtime payload from
the selected backend. A source build is not a software-composition or antivirus approval
for those remote payloads. Packaging them requires their own license and integrity checks.
