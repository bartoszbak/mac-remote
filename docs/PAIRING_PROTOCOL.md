# Pairing and Encryption (protocol v2)

Implemented on the Mac in `ServerManager`, `NetworkServer`, `PairedDeviceStore` and
`Shared/PairingCrypto.swift`, and on iOS in `NetworkClient` and `Pairing/`. Both halves are done; this is the contract they follow.

## Rule

**No pairing, no connection.** The plaintext port only lets a device identify itself
and pair. Every control message, screen data, app list, wake info and lock state goes
over the encrypted link of a paired device. There is no legacy or opt-out mode.

## Ports and discovery

| Port | Transport | Purpose |
|---|---|---|
| `defaultPort` (5150) | plaintext TCP | Bonjour-advertised. `hello`, `welcome`, pairing. Nothing else. |
| `defaultPort + 1` (5151) | TLS 1.2 PSK | Everything else, for paired devices. Runs once at least one device is paired. |

The Bonjour TXT record carries `tlsPort` and `v` (protocol version, currently `2`).

## Connecting

1. The phone opens the plaintext port and sends `hello(deviceID:deviceName:protocolVersion:)`.
2. The Mac replies `welcome(serverID:serverName:protocolVersion:tlsPort:isPaired:controlAllowed:)`.
   `controlAllowed` is always false on plaintext.
3. If the phone holds a key for `serverID`, it opens `tlsPort` with TLS-PSK and is
   connected. Otherwise it starts pairing at once (below). The user never chooses to pair;
   connecting to a new Mac is pairing.
4. If the TLS handshake is rejected (the Mac forgot this phone), the phone drops the key
   and starts pairing again on the still-open plaintext link. If the connection is
   refused right after pairing (listener still starting), it retries briefly.

## Pairing (plaintext port)

```
client                                        server
  │ pairRequest(deviceID, deviceName, clientPub) │
  │─────────────────────────────────────────────▶│  opens "<name> wants to connect" window
  │                                              │  with a fresh 6-digit code (60 s)
  │          pairChallenge(serverPub, salt)      │  secret = X25519(serverPriv, clientPub)
  │◀─────────────────────────────────────────────│
  │ user types the code shown on the Mac         │
  │ pairConfirm(HMAC(session, "client"‖code))    │
  │─────────────────────────────────────────────▶│  verify; one attempt per code
  │   pairResult(true, HMAC(session,"server"‖code), msg) │  store {deviceID, name, psk};
  │◀─────────────────────────────────────────────│  swap TLS listener key set (others stay connected)
  │ verify serverProof; store psk; open TLS      │
```

`session = HKDF(secret, salt, "…session")`, `psk = HKDF(secret, salt, "…psk")`.
A wrong code, expiry, or the user clicking Decline / closing the window ends the request
with `pairResult(false, …)`. The phone offers "Get a New Code", which sends a new
`pairRequest`. Only one request can be open at a time.

All derivations are in `PairingCrypto`; use it verbatim so both sides agree:

- `sharedSecret(privateKey:peerPublicKey:)` — Curve25519 key agreement
- `sessionKey(from:salt:)`, `presharedKey(from:salt:)` — HKDF-SHA256, 32 bytes
- `clientProof(sessionKey:code:)`, `serverProof(sessionKey:code:)`
- `normalizedCode(_:)` — accepts "123 456" style input


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
`PairingCrypto.unlockSignature(presharedKey:challenge:)`. Unpaired devices cannot
unlock. The old 64-character pairing key is gone on both sides.

## Where it lives

- Mac: `ServerManager` (sessions, access control), `NetworkServer.replaceListener`,
  `PairedDeviceStore`, `Views/PairingView.swift` (the request window).
- iOS: `NetworkClient` (connect, pairing, TLS upgrade), `Pairing/PairingCodeView.swift`
  (shown over the connect sheet), `Pairing/PairedMacStore` (Keychain).
- Forgetting: Mac Settings → Devices → Forget, or phone Settings → Forget This Mac.
  Either way the next connection asks for a new code.
