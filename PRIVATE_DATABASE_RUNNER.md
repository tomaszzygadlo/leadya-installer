# Private database qualification

This manual workflow runs on one fresh, standard GitHub-hosted `ubuntu-24.04`
VM. It must never run on a shared or self-hosted machine, or `ubuntu-slim`.
It does not access application servers, their databases, or shared Jenkins.

Only authenticated encrypted inputs enter the job. The original offline Git
bootstrap supplies the unchanged resource policy. The job records real Linux
CPU, available RAM, source/Docker/Maven filesystems, process generations and
pre-existing containers. Its 4 GiB RAM / 6 GiB disk budget requires at least
8 GiB free disk under that policy. This is not a Windows admission ledger.

Diagnostic run `42886461626` identified two operating-system services:
Ubuntu's [networkd-dispatcher](https://packages.ubuntu.com/en/noble/networkd-dispatcher)
and Microsoft's [Azure Linux Agent daemon](https://github.com/Azure/WALinuxAgent).
Only their exact witnessed interpreter/script hashes, root identities, parent PID1,
service cgroups and current systemd MainPID can identify these platform processes.
Changed or unknown processes, including the agent's unclassified child, still count.
These exceptions apply only to the fresh dedicated hosted VM and are recorded with
their actual process generations. They cannot be used for a shared-host admission.
Preflight measurements and census are persisted before the unchanged policy runs;
the separate outcome also preserves partial census when an earlier check refuses.

A real transient cgroup bounds Maven and the pinned MariaDB fixture together
to 4 GiB, two CPU cores and 512 tasks. Maven and its JVM children run without
root, supplementary groups, Docker access or privilege escalation. A real
process witness checks those properties before compilation.

The private source supplies the fixture initializer and its exact test-case
manifest. The worker creates a new database container with a durable exact CID
before start, a bounded memory-backed data directory and a localhost-only port.
It waits for readiness, creates two fresh schemas and a user restricted to them,
then runs the closed suites sequentially in one reused fork. No provider payment,
invoice, cloud-computer or mail request is made by the fixture tests.

Every required class and method must appear exactly once in fresh JDK17 XML,
without failures, errors or skips. Raw reports survive refusal. Final source
hashes, the engine, CID and fixture receipt are checked again. Success additionally
requires closure of the exact container and the whole owned cgroup.

Logs and execution time are bounded. Full private custody records and raw XML
are encrypted with the result key. Only ciphertext and its authenticated envelope
are uploaded. Credentials, passwords and plaintext source are not public artifacts.
Cancellation, missing evidence and uncertain cleanup never qualify as PASS.

The controller must preserve the actual result and independent review before
retiring its own transport secret names. This workflow qualifies tests; it does
not authorize an application commit, deployment or production promotion.
