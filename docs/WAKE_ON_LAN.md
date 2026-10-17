# Waking the Mac from sleep

The Mac side is done. This is the contract for the iOS client.

## What the Mac sends

Right after `welcome` on every connection:

```swift
case wakeInfo(interfaces: [NetworkInterfaceInfo], wakeForNetworkAccessEnabled: Bool)
```

`NetworkInterfaceInfo` (in `Shared/WakeOnLAN.swift`):

| Field | Example | Use |
|---|---|---|
| `name` | `en0` | display only |
| `hardwareAddress` | `fc:b2:14:96:41:8b` | the magic packet target |
| `ipv4Address` | `192.168.1.161` | last known address |
| `ipv4Broadcast` | `192.168.1.255` | where to send the packet |

`wakeForNetworkAccessEnabled` mirrors the Mac's Energy setting (`pmset -g` → `womp`).
If it is false, show "Wake isn't enabled on the Mac" rather than a wake button.

## What the client does

1. **Store** the `wakeInfo` per Mac (keyed by the Bonjour service name or, once paired,
   the Mac's identity) in UserDefaults. It changes rarely.
2. **Wake** by sending `WakeOnLAN.magicPacket(hardwareAddress:)` over UDP to
   `ipv4Broadcast` on port `WakeOnLAN.port` (9), and again on
   `WakeOnLAN.alternatePort` (7). Also send to `255.255.255.255`. Repeat three times,
   300 ms apart. With `NWConnection` use `.udp` parameters; broadcast requires the
   local-network permission the app already has.
3. **When** to wake:
   - a "Wake Mac" button on the connect screen next to a Mac that was seen before but
     is not currently discoverable;
   - automatically, once, when auto-reconnect to a known Mac has failed for ~3 s.
4. After sending, keep browsing: the Mac takes 2–10 s to come back and re-advertise.

## Requirements on the Mac

- "Wake for network access" on (Battery/Energy settings). The Mac app shows this in
  Settings → General → Wake from Sleep and in onboarding, with a shortcut to the pane.
- Ethernet: always works. Wi‑Fi: works on Apple hardware when plugged in; on battery
  macOS may not keep the Wi‑Fi radio listening.
- The phone must be on the same subnet (broadcast does not cross routers).

## Already works without any client change

If an Apple TV, HomePod or another always-on Mac is on the network, the sleeping Mac
registers its Bonjour service with that Sleep Proxy. Connecting to the advertised
service then wakes it automatically. The client can keep connecting to the service
endpoint as usual; the magic packet is the fallback when no proxy exists.
