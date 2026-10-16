# Security

The installer and release tools must never disable antivirus protection, add exclusions,
or describe a successful build as an antivirus verdict. A local Defender Allow decision
invalidates that machine as independent evidence for the affected threat.

Release evidence binds Authenticode, the pinned publisher, a trusted timestamp and a
Defender scan to the same immutable package bytes. The scanner policy is checked before
and after scanning. Assessment mode always reports `publication_ready=false`.
Release paths must be on a local fixed Windows drive, with no reparse components or
alternate data streams. Native handles hold each directory from the root to the parent
and then the file through signature, hash and scanner reads. Tool executables are held
the same way. The signing target keeps its identity while permitting in-place signing.

Report a suspected vulnerability privately to the maintainer using the contact options
on the maintainer's GitHub profile. If no private channel is listed, open an issue asking
for one without including exploit instructions, credentials, customer data or attachments.

Signing keys, certificates containing private keys, tokens, customer configuration and
application payloads do not belong in this repository. Third-party code-signing services
require separate enrollment; open source does not itself grant a trusted certificate or
guarantee that antivirus products will never report a detection.
