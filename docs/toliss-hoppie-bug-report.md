# Bug Report: Hoppie ACARS Connection Failure with IPv6 Enabled on Windows

## Summary

The ToLiss ACARS/Hoppie integration fails to establish a connection when IPv6 is enabled on the Windows network adapter, while other applications (browsers, curl, custom scripts) can connect to hoppie.nl without issues.

## Environment

- Platform: Windows (issue not observed on macOS)
- Aircraft: ToLiss A321 (likely affects all ToLiss aircraft with Hoppie integration)
- Network: Dual-stack (IPv4 + IPv6) connectivity
- Symptom: ISCS shows "CHECKING ID PLEASE WAIT" indefinitely

## Steps to Reproduce

1. Enable IPv6 on the Windows network adapter
2. Load a ToLiss aircraft
3. Configure Hoppie logon code in ISCS
4. Attempt to connect to Hoppie network
5. Observe: Connection never completes, stays on "CHECKING ID"

## Workaround

Disabling IPv6 on the network adapter resolves the issue immediately.

## Root Cause Analysis

**Note: The following technical analysis was generated with AI assistance (Claude) and should be verified by the development team.**

### DNS Configuration Difference

```
hoppie.nl:    A = 94.142.246.179,  AAAA = 2a02:898:62:f6::b3
simbrief.com: A = 192.95.16.233,  AAAA = (none)
```

Hoppie.nl publishes both IPv4 (A) and IPv6 (AAAA) DNS records, while SimBrief only publishes IPv4. This explains why SimBrief connections work while Hoppie connections fail.

### Suspected Mechanism

When `getaddrinfo()` resolves hoppie.nl on a dual-stack Windows system, it returns both address families. The operating system typically prefers IPv6. In non-blocking or asynchronous socket operations:

1. The socket library initiates an IPv6 connection first
2. If the user's IPv6 path to hoppie.nl is broken (ISP routing issues, tunnel problems, etc.), the connection attempt may hang or fail silently
3. In blocking mode, this would eventually timeout and fall back to IPv4
4. In non-blocking/async mode, the fallback to the next address in the `addrinfo` chain may not be properly implemented, causing the connection to remain in a pending state indefinitely

### Why This Might Occur

Many HTTP/socket libraries have subtle differences in async IPv6 handling on Windows, particularly around:
- Winsock `WSAConnect` completion behavior on connection failure
- IOCP (I/O Completion Ports) notification edge cases
- Happy Eyeballs (RFC 8305) implementation in async contexts

Libraries like libcurl handle this correctly by racing IPv4 and IPv6 connections simultaneously, using whichever succeeds first.

## Suggested Investigation

1. Verify which HTTP/socket library is used for Hoppie connections
2. Check if the library properly iterates through `getaddrinfo()` results on async connection failure
3. Consider forcing `AF_INET` (IPv4 only) for Hoppie connections as a temporary fix
4. Or evaluate using a library with robust Happy Eyeballs support (e.g., libcurl)

## Additional Context

- The same Hoppie logon code works correctly when used from external tools (Ruby scripts, browsers)
- Messages sent to the user's callsign appear correctly in the Hoppie message log
- The callsign shows as "offline" (red) in Hoppie's system, confirming the aircraft is not polling

---

Thank you for your continued excellent work on the ToLiss aircraft. This is a subtle edge case that only manifests under specific network conditions, and I hope this analysis helps in tracking down the issue.

Respectfully submitted.
