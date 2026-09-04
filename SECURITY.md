# Security policy

## Reporting a vulnerability

Report privately through GitHub: open the repository's **Security** tab and
choose **Report a vulnerability** (a private security advisory). Do not open a
public issue, and do not include a working exploit in a public comment.

Useful in a report: what an attacker has to be able to do (be on the same
Wi-Fi, be a paired peer, be an unpaired peer), which side is affected (macOS
app, Finder extension, Android companion), and the transport involved (stock
Quick Share or the paired companion protocol).

Expect an acknowledgement within a week. This is a small personal project with
no paid bounty.

## Trust model

These rules are stated in [AGENTS.md](AGENTS.md) and
[docs/companion-protocol.md](docs/companion-protocol.md); they are repeated
here so a reporter can see what the code already intends to guarantee.

- **Everything from a peer is hostile.** Remote names, MIME types, lengths, and
  metadata are untrusted input, not hints.
- **Filenames are sanitized before any filesystem use.** On Android, every
  output filename goes through `storage/IncomingFilename.sanitize` before
  MediaStore sees it.
- **Advertised sizes and counts are capped**, and peer labels are normalized
  before being displayed.
- **A paired Mac pins exactly one Android certificate.** Both sides derive the
  six-digit comparison code from the pairing challenge and the fingerprint of
  the TLS certificate actually presented; later connections
  require that exact certificate and never fall back to system trust. The
  stored token is sent only over that pinned connection.
- **mDNS TXT data is hostile discovery metadata.** A paired row is usable only
  when the live record advertises the fingerprint stored at pairing time — not
  a remembered address and not a display-name match.
- **Stock Quick Share keeps its own protections.** UKEY2/D2D encryption, the
  QR token match, and the safe-disconnect exchange are not weakened to
  diagnose interoperability.
- **Transfers are local-network only.** There is no cloud relay and no
  internet route.

A report that shows any of the above failing in practice is exactly the kind
of report this policy is for.
