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
  `--plugin-directory`: AccessControl.dll, INetC.dll, nsisunz.dll, ShellExecAsUser.dll.

Official plugin sources and release archives:

| Component | Source | License evidence |
|---|---|---|
| AccessControl | https://nsis.sourceforge.io/AccessControl_plug-in | zlib-style notice in Contrib/AccessControl/AccessControl.cpp |
| INetC | https://nsis.sourceforge.io/Inetc_plug-in | NSIS project notices; preserve the complete upstream archive and notices |
| nsisunz Unicode | https://nsis.sourceforge.io/Nsisunz_plug-in | zlib-style notice in the distribution readme; bundled zlib notices also apply |
| ShellExecAsUser | https://nsis.sourceforge.io/ShellExecAsUser_plug-in | published NSIS Wiki default zlib/libpng terms; bundled VistaTools has its own permissive terms retained in NOTICE |

No plugin DLL, NSIS SDK, Java runtime or application binary is redistributed by this source
repository. Supply dependencies whose use and distribution you are authorized to perform.
For the unchanged ShellExecAsUser Unicode DLL we rely on the combination of the author's
official upload, the Wiki contribution/default-license declaration, the earlier published
plugin license policy, no conflicting plugin-specific term, and exact binary identity.
This is an inference from those published grants, not from source availability alone.
The contribution notice dates from 2006 and the license policy revision from 2013,
before the author's 2018 upload. Different versions or modifications need a fresh check.

- [Wiki rights metadata](https://nsis.sourceforge.io/mediawiki/api.php?action=query&meta=siteinfo&siprop=rightsinfo&format=json)
- [Contribution terms, revision 9345](https://nsis.sourceforge.io/mediawiki/index.php?title=MediaWiki:Copyrightwarning&oldid=9345)
- [NSIS license policy](https://nsis.sourceforge.io/License)
- [Author's file record](https://nsis.sourceforge.io/File:ShellExecAsUserUnicodeUpdate.zip)
- [Original author forum thread](https://nsis-dev.github.io/NSIS-Forums/html/t-335435.html)

The [Unicode archive](https://nsis.sourceforge.io/mediawiki/images/1/1d/ShellExecAsUserUnicodeUpdate.zip)
has SHA-256 `79bdd3e54a9ba9c30af85557b475d2322286f8726687f2e23afa772aac6049ab`.
Its 44032-byte `unicode/ShellExecAsUser.dll` has SHA-256
`1f17e4d5ffe7b2c9a396ee9932ac5198f0c050241e5f9ccd3a56e576613d8a29`.
Preserve the upstream source notices, including the distinct WinAbility/VistaTools
terms reproduced in NOTICE. Do not label these components as first-party Apache code.
The LeadYa build retains its existing dependency set and version history.

The installer currently downloads the separately licensed application/runtime payload from
the selected backend. A source build is not a software-composition or antivirus approval
for those remote payloads. Packaging them requires their own license and integrity checks.
