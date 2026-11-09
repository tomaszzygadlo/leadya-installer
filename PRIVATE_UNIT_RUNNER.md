# Private Windows unit evidence

This branch supplies a private application unit-test runner, independent of the
post-deployment browser workflow. It does not deploy, sign installers, launch bots,
or authorize external messages. Only the operator prepares keys, the authenticated
source payload, an immutable input commit, and a workflow dispatch.

The workflow runs on Windows X64 with image JDK17, Maven, Node and Python3.12.
It materializes the existing small offline Git checkout solely for the unchanged
canonical resource gate. Both source directories occupy the same runner drive.
Heavy admission requests 2 GiB memory and 3 GiB disk before decrypting the larger
application closure or starting Maven. A refused admission stops execution.

## Authenticated input

Dispatch requires `input_ref` (40 lowercase hex commit), `red_tree`, `green_tree`
(40 lowercase hex trees), and `source_zip_sha256` (64 lowercase hex). The public
input commit contains only `source.cipher` and `source-envelope.json`; no private
application source is published. Keep ciphertext below the hosting file limit.

`DEVUNIT_SOURCE_KEY` is one base64 32-byte repository secret. AES256-GCM uses a
fresh 12-byte nonce, 16-byte tag, and literal AAD:

```
leadya-private-unit-source/v1|<red_tree>|<source_zip_sha256>
```

The envelope fields are `format: leadya-private-unit-source/v1`, `red_tree`,
`nonce_base64`, `tag_base64`, `aad_utf8`, `cipher_sha256`, `plaintext_sha256`.
The last field equals the dispatch ZIP digest. Authentication and digest checks
finish before writing any plaintext ZIP.

ZIP physical entries are exactly `source/<path>` and these four controls:

- `control/source-manifest.json`
- `control/green-manifest.json`
- `control/green.patch`
- `control/unit-spec.json`

No explicit directory entries are needed. Limits: 128 MiB ZIP, 768 MiB total
uncompressed content, 12,000 source files plus four controls, 32 MiB per control.
Both manifests have format `leadya-private-unit-manifest/v1`, `tree`, `inventory`
and `source_files`. The inventory allows up to 50,000 tracked Git leaf entries
`{path,mode,git_blob}` including excluded media/docs as metadata only; extra
`kind` and `tree_role` metadata is accepted. Independent Git Merkle recomputation
must match the expected tree. Materialized regular blobs have
`{path,mode,git_blob,bytes,sha256}` and must be an exact inventory subset. Symlinks,
submodules and unsafe Windows paths cannot be materialized. Secrets, settings.xml,
private Git metadata and generated dependency/build directories are refused.

## Closed execution specification

`unit-spec.json` uses format `leadya-private-unit-spec/v1`, `compile_modules`,
`red:{module,class,method,failure_contains}`, `green:[{module,tests:[class]}]`,
`node:[relative test paths]` and `green_patch_sha256`. No shell snippets are accepted.
Only the module allowlist in `private_unit_ci.py` is executable. Vendor source POMs
SeleniumModule and CaptchaSolverModule are installed first, then the module closure
is clean-compiled and installed with tests skipped for this compilation step.
Every Maven invocation sets `-Dmaven.antrun.skip=true`: the source POMs bind
deployment JAR copies outside `target` to install. This unit-only property leaves
the application POMs unchanged and keeps the strict source manifest intact. The
property is supported by the POMs' [AntRun3.0.0 plugin](https://maven.apache.org/components/plugins-archives/maven-antrun-plugin-3.0.0/run-mojo.html).

The selected RED method runs separately. It must produce exactly one assertion
failure with the named class/method and expected text, no error or skip. Compilation
failure or missing reports cannot satisfy RED. Only then does the exact hashed
green patch run. All changed Git blobs must match the prospective GREEN tree.
The closure is clean-compiled again, followed by separate selected module tests.
GREEN must include the exact RED method, now passing. No AgentCore tests or its
Linux-only isolation profile run in this Windows scope; do not change source POMs
to bypass them. Those tests remain outside this runner's selected scope.

Frontend dependencies use `npm ci --ignore-scripts` from the authenticated lockfile
in SpringAppFrontend/src/test/js. Selected Node tests run with concurrency one.
JUnit and TAP evidence must be nonempty and contain zero skips in GREEN.

## Process and evidence custody

Python entry points use pythonw.exe. Native process creation uses an atomic Windows
Job List attribute, explicit inherited handle list, hidden startup, bounded logs,
timeouts and KILL_ON_JOB_CLOSE. The job owns descendants before execution. Parent
exit, timeout and log cap terminate only that job. Its cleanup marker requires
ActiveProcesses zero before the workflow releases its own admission receipt.
This follows the Windows [job object documentation](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
and [process attribute contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute).

Maven/Node receive a fixed environment allowlist without source/result keys, browser
authentication or GitHub credentials. This is custody for authenticated owned source,
not a sandbox for hostile code sharing the runner's user account. Git checkout does
not persist credentials. Bootstrap source secrets are supplied only to the original
small source materializer; browser authentication is never read by this workflow.

Only AES-GCM ciphertext and its envelope are uploaded. Existing B7 RESULT_KEY is
read only by the final sealing step, with a fresh nonce and distinct result AAD:

```
leadya-private-unit-result/v1|<red_tree>|<green_tree>|<source_zip_sha256>|<workflow_sha>|<run_id>
```

Logs, assertions and JUnit XML stay inside encrypted results, retained seven days.
The operator verifies ciphertext, GCM, all identities, actual JUnit counts and the
`CAUSAL_RED_GREEN_PASS` status before using this evidence. A successful workflow
without that evidence is not an application test pass. The input GREEN remains
prospective until the operator applies the same patch in the normal checkout and
confirms its staged tree before review and commit.

## Lightweight guard checks

Run `test_private_unit_ci.py` through pythonw with a log path; run
`Test-PrivateUnitProcess.ps1 -Output <json>` and
`Test-PrivateUnitCrypto.ps1 -Output <json>` through hidden PowerShell7. They use only
synthetic fixtures, native child processes and small temporary files, without Maven,
JVM, browsers or private keys. They cover real normal-index Git Merkle proof,
source tampering, paths, causal assertions, skips, missing GREEN regression,
metadata/file limits, native exit/timeout/log cap/descendant cleanup, absent secret
environment and authenticated decryption/tamper rejection.
