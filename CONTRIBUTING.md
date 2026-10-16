# Contributing

Open an issue describing the observable problem and a reproducible scenario. Keep changes
small and include a test for failures involving file paths, privileges, data custody,
package integrity or release policy.

Run `python -m unittest -v test_build` and, on Windows, the PowerShell policy and native
process tests. Run a real NSIS compilation when changing the template or compiler adapter.
Never execute an untrusted installer on your normal workstation for a test.

Contributions to first-party installer code are accepted under Apache-2.0. Preserve existing
third-party notices and identify the origin and license of any new dependency. Do not submit
private application code, signing material, user profiles, production settings or generated
installer binaries in a pull request.
