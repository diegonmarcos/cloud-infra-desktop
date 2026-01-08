Windows Product Key (from BIOS/UEFI MSDM table)
================================================

OS Edition:  Windows 11 Home
Key:         9XBNP-XRJPM-QP2YQ-DCY7J-F3KTQ

Hardware
--------
Device:      Surface Pro 8
Manufacturer: Microsoft Corporation
Serial:      0F03U2G223201J

Notes
-----
- OEM key embedded in UEFI firmware
- Auto-activates during Windows reinstall (requires internet)
- Key is tied to this specific hardware

---

BitLocker Recovery Keys
=======================

Surface Pro 8 - OS Drive
------------------------

| Key ID | Recovery Key |
|--------|--------------|
| 6CF388CD | 157443-184492-647768-246356-300476-544335-014597-679767 |

Other devices: See `bitlocker_other_devices.md`

How to Find BitLocker Key
-------------------------

**Option 1: From Windows**
```
Settings → Privacy & Security → Device encryption → BitLocker recovery key
```

**Option 2: From Microsoft Account**
```
https://account.microsoft.com/devices/recoverykey
```

**Option 3: From Command Line (Admin PowerShell)**
```cmd
manage-bde -protectors -get C:
```

---

IMPORTANT: Save BitLocker Key BEFORE
------------------------------------
- [ ] Changing bootloader
- [ ] Disabling Secure Boot
- [ ] Modifying EFI partition
- [ ] Booting from USB
- [ ] Installing rEFInd
