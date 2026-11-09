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
input commit contains `source.cipher`, `source-envelope.json`, `bootstrap.cipher`
and `bootstrap-envelope.json`; no private
application source is published. Keep ciphertext below the hosting file limit.

The isolated `LEADYA_FC3_705BE814AC92_` namespace owns exactly three independent
base64 32-byte repository secrets: `BOOTSTRAP_KEY`, `SOURCE_KEY`, `RESULT_KEY`.
The operator first checks that those names and both new branch refs do not exist.
Only the operator's keys may be created or removed; retain them until every run
using this workflow is terminal and its encrypted results are safely preserved.
No previous namespace or another operator's source key is used.

`SOURCE_KEY` is mapped to `DEVUNIT_SOURCE_KEY` only in the source decryption step.
AES256-GCM uses a
fresh 12-byte nonce, 16-byte tag, and literal AAD:

```
leadya-private-unit-source/v1|<red_tree>|<source_zip_sha256>
```

The envelope fields are `format: leadya-private-unit-source/v1`, `red_tree`,
`nonce_base64`, `tag_base64`, `aad_utf8`, `cipher_sha256`, `plaintext_sha256`.
The last field equals the dispatch ZIP digest. Authentication and digest checks
finish before writing any plaintext ZIP.

The bootstrap uses its own `DEVUNIT_BOOTSTRAP_KEY` mapping and distinct domain:

```
leadya-private-unit-bootstrap/v1|<bootstrap_commit>|<bootstrap_tree>|<bootstrap_sha256>|<red_tree>|<green_tree>|<source_zip_sha256>
```

Bootstrap commit, tree and archive digest are pinned in the workflow and crypto
implementation. The envelope adds `bootstrap_commit` and `bootstrap_tree`, uses
format `leadya-private-unit-bootstrap/v1`, and includes the same GCM fields and
`red_tree` as the source envelope. Ciphertext is bounded to 4 MiB. Authentication
and the exact pinned plaintext digest are checked before writing the archive.
The original materializer reads that local archive, validates its original full
offline Git closure, and receives no key or chunk environment variables.

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
Bounded RED and each GREEN JUnit report set is preserved inside encrypted results
before its evidence guard runs, including refusals. Execution status records the
current stage and becomes FAILED with a closed guard code on handled failure; assertions
and report contents never appear in public workflow output.
An external native-job timeout or forced termination can prevent Python from
writing its final state. A leftover RUNNING state or a failed/incomplete workflow
is never PASS; acceptance requires the authenticated final CAUSAL_RED_GREEN_PASS
evidence and successful workflow, not the absence of a FAILED field.

## Process and evidence custody

Python entry points use pythonw.exe. Native process creation uses an atomic Windows
Job List attribute, explicit inherited handle list, hidden startup, bounded logs,
timeouts and KILL_ON_JOB_CLOSE. The job owns descendants before execution. Parent
exit, timeout and log cap terminate only that job. Its cleanup marker requires
ActiveProcesses zero before the workflow releases its own admission receipt.
The private entry wrapper matches direct Python script import resolution by adding
the pinned target script directory to sys.path. Exceptions are recorded before the
private stream closes. The admission acquire log and its native transport log are
inside encrypted results, including when admission refuses; the private lease
receipt stays outside artifacts. Missing application test evidence remains NOT_RUN.
This follows the Windows [job object documentation](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
and [process attribute contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute).

Maven/Node receive a fixed environment allowlist without source/result keys, browser
authentication or GitHub credentials. This is custody for authenticated owned source,
not a sandbox for hostile code sharing the runner's user account. Git checkout does
not persist credentials. Bootstrap keys reach only the bootstrap decryption step;
the child allowlist contains no secret keys. Browser authentication is never read.

Only AES-GCM ciphertext and its envelope are uploaded. The new owned RESULT_KEY is
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

Every Maven invocation receives an owned WARN Logback configuration in the encrypted
result directory, outside the authenticated application source. `logback.configurationFile`
configures Logback and `logging.config` also covers Spring Boot initialization.
The console threshold preserves WARN/ERROR and exception stacks; JUnit results and
assertions remain independent of logging. The 32 MiB command-log, 64 MiB report-total
and sealed-result limits remain unchanged. No POM, application code or test is modified.
Each actual Surefire XML must contain the exact forwarded `logback.configurationFile`
property; otherwise the run refuses the evidence after preserving it.

Property forwarding was checked against the [Surefire 2.22.2 source](https://github.com/apache/maven-surefire/blob/surefire-2.22.2/maven-surefire-common/src/main/java/org/apache/maven/plugin/surefire/AbstractSurefireMojo.java):
`setupProperties()` combines Maven user properties with configured system properties
before creating the provider. Logback's [configuration documentation](https://logback.qos.ch/manual/configuration.html)
specifies that `logback.configurationFile` selects the configuration before classpath
defaults. Local guards verify XML, real Windows command quoting and property evidence;
the application run must still prove forwarding and its own test results.

Run `test_private_unit_ci.py` through pythonw with a log path; run
`Test-PrivateUnitProcess.ps1 -Output <json>` and
`Test-PrivateUnitCrypto.ps1 -Output <json>` through hidden PowerShell7. They use only
synthetic fixtures, native child processes and small temporary files, without Maven,
JVM, browsers or private keys. They cover real normal-index Git Merkle proof,
source tampering, paths, causal assertions, skips, missing GREEN regression,
metadata/file limits, native exit/timeout/log cap/descendant cleanup, absent secret
environment and authenticated decryption/tamper rejection.
