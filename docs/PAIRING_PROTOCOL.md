# Pairing and Encryption (protocol v2)

Implemented on the Mac in `ServerManager`, `NetworkServer`, `PairedDeviceStore` and
`Shared/PairingCrypto.swift`. This document is the contract the iOS client implements.

## Ports and discovery

| Port | Transport | Purpose |
|---|---|---|
| `defaultPort` (5150) | plaintext TCP | Bonjour-advertised. Discovery, `hello`, pairing. Control messages only while the Mac's **Allow unencrypted connections** setting is on (legacy mode). |
| `defaultPort + 1` (5151) | TLS 1.2 PSK | Control for paired devices. Only runs once at least one device is paired. |

The Bonjour TXT record carries `tlsPort` and `v` (protocol version, currently `2`).
Read `tlsPort` from the browse result's TXT record; fall back to port + 1.

## Connection handshake

On every connection (either port) the server sends, in order:

1. `connected(screenWidth:screenHeight:unlockChallenge:unlockAvailable:)` (v1, unchanged)
2. `welcome(serverName:protocolVersion:tlsPort:isPaired:controlAllowed:)`

The client should send `hello(deviceID:deviceName:protocolVersion:)` first.
`deviceID` is a stable per-install UUID (store it in the Keychain). The server
replies with a fresh `welcome` reflecting whether this device is paired.

`controlAllowed == false` means the server will ignore control messages on this
connection and reply once with `error(...)`. The client should show "This Mac
requires pairing" and offer to pair.

## Pairing flow (plaintext port, while the Mac shows a code)

```
client                                        server
  │ pairRequest(deviceID, deviceName, clientPub) │
  │─────────────────────────────────────────────▶│  window open? else pairResult(false)
  │                                              │  serverPriv/serverPub, salt = 16 random bytes
  │          pairChallenge(serverPub, salt)      │  secret = X25519(serverPriv, clientPub)
  │◀─────────────────────────────────────────────│
  │ secret = X25519(clientPriv, serverPub)       │
  │ session = HKDF(secret, salt, "…session")     │
  │ psk     = HKDF(secret, salt, "…psk")         │
  │ pairConfirm(HMAC(session, "client"‖code))    │
  │─────────────────────────────────────────────▶│  verify; one attempt only
  │   pairResult(true, HMAC(session,"server"‖code), msg) │
  │◀─────────────────────────────────────────────│  store {deviceID, name, psk}
  │ verify serverProof; store psk                │  restart TLS listener with new key set
```

All derivations are in `PairingCrypto`; use it verbatim so both sides agree:

- `sharedSecret(privateKey:peerPublicKey:)` — Curve25519 key agreement
- `sessionKey(from:salt:)`, `presharedKey(from:salt:)` — HKDF-SHA256, 32 bytes
- `clientProof(sessionKey:code:)`, `serverProof(sessionKey:code:)`
- `normalizedCode(_:)` — accepts "123 456" style input

The code is 6 digits and valid for 60 seconds. A wrong code closes the window; the
user must request a new code on the Mac.

## Encrypted connections

After pairing, connect to `tlsPort` with TLS-PSK:

```swift
let tls = NWProtocolTLS.Options()
let sec = tls.securityProtocolOptions
sec_protocol_options_add_pre_shared_key(sec, pskDispatchData, identityDispatchData)   // identity = deviceID (UTF-8)
sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
let params = NWParameters(tls: tls, tcp: tcpOptions)
```

`NetworkServer.clientTLSOptions(identity:key:)` builds exactly this and is what the
Mac's loopback tests use. Framing on the TLS connection is identical (4-byte length
prefix + JSON). Send `hello` first.

If the handshake fails (device was forgotten on the Mac), the connection sits in
`.waiting`; treat that as "no longer paired", drop the stored PSK and offer to pair again.

## Unlock with a paired device

Paired devices sign the unlock challenge with the PSK:
`PairingCrypto.unlockSignature(presharedKey:challenge:)`. The legacy pairing-key
flow still works for v1 clients and can be removed once the client ships pairing.

## Client checklist

- [ ] Generate and persist `deviceID`
- [ ] Send `hello` on connect; handle `welcome`
- [ ] Read `tlsPort` from TXT; prefer the TLS port when a PSK for this Mac is stored
- [ ] Pairing UI: 6-digit code entry; run the flow above on the plaintext port
- [ ] Store `{macID or service name → psk}` in the Keychain
- [ ] Handle `controlAllowed == false` with a "Pair this Mac" prompt
- [ ] Switch unlock to `unlockSignature(presharedKey:challenge:)`
