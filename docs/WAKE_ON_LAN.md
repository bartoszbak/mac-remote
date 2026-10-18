# Waking the Mac from sleep

Both sides are implemented. Tested 2026-10-18 on a MacBook Pro (M5 Max) on Wi‑Fi.

## How a sleeping Mac gets woken

1. **Bonjour Sleep Proxy (preferred).** With "Wake for network access" on for the current
   power source, the sleeping Mac hands its Bonjour service to a Sleep Proxy (Apple TV,
   HomePod, always-on Mac). The Mac stays listed on the phone, and connecting to it makes
   the proxy wake the Mac. No magic packet or entitlement involved.
2. **Magic packet (fallback).** The phone sends one on every connect to a known Mac and
   from the Wake button: unicast to the last known IPv4 (works without entitlements) and
   broadcast (refused on iOS without the multicast entitlement; harmless).
3. **Full wake.** A network wake is a dark wake. When a paired device connects (or a new
   one asks to pair), the Mac declares user activity so the display comes on, and holds a
   no-idle-sleep assertion while any device is connected (`PowerAssertions`).

## Limits

- Laptops: network wake only works **on power**. On battery macOS ignores it.
- On power a laptop usually never idle-sleeps, so the real case is *plugged in, lid closed*.
- Closing the lid still sleeps the Mac even while a phone is connected.
- The phone times out after 25 s with a hint if the Mac never answers.


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

`wakeForNetworkAccessEnabled` is the **on-power** setting (`pmset -g custom` → AC Power → `womp`), regardless of the current power source.
If it is false, show "Wake isn't enabled on the Mac" rather than a wake button.

## What the client does

1. **Store** the `wakeInfo` per Mac (keyed by the Bonjour service name or, once paired,
   the Mac's identity) in UserDefaults. It changes rarely.
2. **Wake** by sending `WakeOnLAN.magicPacket(hardwareAddress:)` with a plain UDP socket
   (`WakeOnLANSender`): unicast to `ipv4Address`, broadcast with `SO_BROADCAST` to
   `ipv4Broadcast` and `255.255.255.255`, ports 9 and 7, three times 300 ms apart.
   Do not use `NWConnection` for broadcast: it fails with EACCES (verified).
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
