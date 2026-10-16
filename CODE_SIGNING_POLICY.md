# Code signing policy

**Status: SignPath Foundation approval and signing setup are pending.**
Current CI artifacts are unsigned and have `publication_ready=false`. A passing build
does not establish a trusted signature or an antivirus verdict.

We are applying for free code signing provided by SignPath.io, certificate by
SignPath Foundation. If accepted, the certificate's publisher will be SignPath
Foundation. Acceptance, signing configuration and manual approval of each signing
request must happen before we describe any artifact as Foundation-signed.

## Scope and responsibilities

- Project: https://github.com/tomaszzygadlo/leadya-installer; first-party source is Apache-2.0.
- Maintainer, committer, reviewer and proposed signing approver: Tomasz Żygadło
  ([tomaszzygadlo](https://github.com/tomaszzygadlo)).
- Signing is proposed only for this repository's installer built from its reviewed source
  by GitHub Actions. Origin verification and manual release approval must be configured
  with SignPath after acceptance. All signing participants must use multi-factor
  authentication before signing is activated; this page does not assert it has been verified.
- The installer downloads the separately licensed, closed-source commercial LeadYa
  application and third-party Java/Chromium components. Their binaries are outside this
  signing request. Whether this bootstrapper qualifies remains for the Foundation to decide.
- Third-party NSIS code/plugins retain their upstream notices and are not presented as
  first-party Apache source. See [dependencies](DEPENDENCIES.md) and [notices](NOTICE).

## Privacy

On the user's installation request, the bootstrapper downloads components over HTTPS
from the configured backend (default `backend.turbot.pro`). The server receives the
network address and ordinary HTTP request metadata needed for those downloads.
This repository does not request LeadYa account credentials for the source build or
signing request. The separately licensed application has its own functionality and
data-processing terms; this policy is not a privacy assurance for that application.

Signing submissions would contain this project's build artifacts and provenance, not
customer configuration, browser profiles, credentials or private application source.
SignPath's processing is described in its [privacy policy](https://signpath.io/privacy-policy).
