# Windows 11 Webcam Setup Guide

> **Purpose**: Minimal Windows 11 for Surface Pro 8 webcam driver compatibility
> **Partition**: nvme0n1p4 (~20GB NTFS)
> **Status**: Unencrypted (Zone 1)

---

## Overview

The Surface Pro 8 webcam requires Windows-specific drivers. This minimal Windows 11 installation provides webcam functionality that can be streamed to NixOS.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          WINDOWS 11 WEBCAM SETUP                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                         SURFACE PRO 8                                  │  │
│  │                                                                        │  │
│  │   Windows 11 (Webcam Only)                                            │  │
│  │   ┌──────────────────┐                                                │  │
│  │   │  Surface Webcam  │────► OBS Studio ────► NDI/RTSP Stream          │  │
│  │   │  Driver          │                              │                 │  │
│  │   └──────────────────┘                              │                 │  │
│  │                                                      │                 │  │
│  │   NixOS Host                                         ▼                 │  │
│  │   ┌──────────────────────────────────────────────────────────┐        │  │
│  │   │  v4l2loopback ◄─── ffmpeg/NDI receiver ◄─── Network      │        │  │
│  │   │  /dev/video10                                             │        │  │
│  │   └──────────────────────────────────────────────────────────┘        │  │
│  │                                                                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Windows 11 ISO (from Microsoft)
- 20GB+ free partition
- USB drive for installation
- Internet connection for drivers

---

## Phase 1: Create Partition

From Alpine Recovery or NixOS:

```bash
# Check current layout
sudo fdisk -l /dev/nvme0n1

# Create ~20GB partition (after Alpine, before LUKS)
sudo parted /dev/nvme0n1
(parted) mkpart primary ntfs 7GB 27GB
(parted) quit

# Verify
lsblk
```

---

## Phase 2: Install Windows 11

### Step 1: Boot from USB

1. Create bootable Windows 11 USB (Rufus or Ventoy)
2. Boot Surface Pro 8
3. Press Volume Down + Power to access UEFI
4. Select USB boot

### Step 2: Installation Options

During setup:
- Select "Custom: Install Windows only"
- Select the ~20GB partition (nvme0n1p4)
- **DO NOT** format other partitions
- Choose "Windows 11 Home" (smaller footprint)

### Step 3: OOBE Setup

- Select region/language
- **IMPORTANT**: Disconnect network to skip Microsoft account
- Use local account: `User` / `1234567890`
- Disable all telemetry options
- Skip Cortana setup

---

## Phase 3: Debloat Windows

### Step 1: Remove Bloatware

Open PowerShell as Administrator:

```powershell
# Remove pre-installed apps
Get-AppxPackage *Microsoft.549981C3F5F10* | Remove-AppxPackage  # Cortana
Get-AppxPackage *Microsoft.BingWeather* | Remove-AppxPackage
Get-AppxPackage *Microsoft.GetHelp* | Remove-AppxPackage
Get-AppxPackage *Microsoft.Getstarted* | Remove-AppxPackage
Get-AppxPackage *Microsoft.MicrosoftOfficeHub* | Remove-AppxPackage
Get-AppxPackage *Microsoft.MicrosoftSolitaireCollection* | Remove-AppxPackage
Get-AppxPackage *Microsoft.People* | Remove-AppxPackage
Get-AppxPackage *Microsoft.WindowsFeedbackHub* | Remove-AppxPackage
Get-AppxPackage *Microsoft.Xbox* | Remove-AppxPackage
Get-AppxPackage *Microsoft.YourPhone* | Remove-AppxPackage
Get-AppxPackage *Microsoft.ZuneMusic* | Remove-AppxPackage
Get-AppxPackage *Microsoft.ZuneVideo* | Remove-AppxPackage
Get-AppxPackage *Clipchamp* | Remove-AppxPackage
```

### Step 2: Disable Telemetry

```powershell
# Disable telemetry services
sc config DiagTrack start= disabled
sc config dmwappushservice start= disabled

# Disable Connected User Experiences
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f

# Disable advertising ID
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f
```

### Step 3: Disable Windows Update (Optional)

```powershell
# Disable Windows Update service
sc config wuauserv start= disabled
sc stop wuauserv

# Or just pause updates for 5 weeks in Settings
```

### Step 4: Disable Defender Real-Time (Optional)

Settings > Privacy & Security > Windows Security > Virus & threat protection > Manage settings > Turn off Real-time protection

---

## Phase 4: Install Surface Drivers

### Step 1: Connect to Network

Connect to WiFi temporarily to download drivers.

### Step 2: Install Surface Drivers

1. Open Settings > Windows Update
2. Check for updates (Surface drivers will appear)
3. Install all Surface-related updates
4. Restart

### Step 3: Verify Webcam

1. Open Camera app
2. Verify webcam works
3. Check Device Manager for Surface Camera

---

## Phase 5: Install OBS Studio

### Step 1: Download OBS

Download from: https://obsproject.com/

### Step 2: Configure OBS

1. Add Video Capture Device source
2. Select Surface Camera
3. Set resolution (1080p recommended)
4. Set framerate (30fps recommended)

### Step 3: Configure Virtual Camera

1. Tools > VirtualCam
2. Start Virtual Camera
3. This creates a loopback video device

---

## Phase 6: Network Streaming Setup

### Option A: NDI (Recommended)

**Windows Side:**
1. Install NDI Tools from ndi.tv
2. In OBS: Tools > NDI Output Settings
3. Enable Main Output
4. Name: "Surface-Webcam"

**NixOS Side:**
```nix
# configuration.nix
environment.systemPackages = with pkgs; [
  obs-studio
  obs-studio-plugins.obs-ndi
];
```

```bash
# Receive NDI stream
obs-ndi  # Will auto-discover "Surface-Webcam"
```

### Option B: RTSP via ffmpeg

**Windows Side (OBS):**
1. Settings > Stream
2. Service: Custom
3. Server: `rtsp://localhost:8554/webcam`

Install rtsp-simple-server:
```
# Download from GitHub releases
rtsp-simple-server.exe
```

**NixOS Side:**
```bash
# Create virtual camera device
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="Surface Webcam"

# Receive RTSP stream to virtual device
ffmpeg -i rtsp://WINDOWS_IP:8554/webcam -f v4l2 /dev/video10
```

### Option C: MJPEG over HTTP

**Windows Side:**
Use OBS with obs-websocket + custom script, or use ffmpeg:
```
ffmpeg -f dshow -i video="Surface Camera" -vcodec mjpeg -f mjpeg http://0.0.0.0:8080/webcam.mjpg
```

**NixOS Side:**
```bash
# Create loopback
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="Surface Webcam"

# Receive MJPEG
ffmpeg -i http://WINDOWS_IP:8080/webcam.mjpg -f v4l2 /dev/video10
```

---

## Phase 7: Add Boot Entry

### rEFInd Configuration

```bash
# /boot/efi/EFI/refind/refind.conf

menuentry "Windows 11 (Webcam)" {
    icon     /EFI/refind/icons/os_win11.png
    volume   "Windows"
    loader   /EFI/Microsoft/Boot/bootmgfw.efi
}
```

### GRUB Configuration

```bash
# /etc/grub.d/40_custom

menuentry "Windows 11 (Webcam)" {
    insmod part_gpt
    insmod ntfs
    search --no-floppy --fs-uuid --set=root WINDOWS_UUID
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
```

---

## Streaming Comparison

| Method | Latency | Quality | Complexity | Firewall |
|--------|---------|---------|------------|----------|
| **NDI** | ~50ms | Excellent | Medium | Port 5961+ |
| **RTSP** | ~100ms | Good | Medium | Port 8554 |
| **MJPEG HTTP** | ~200ms | Fair | Low | Port 8080 |
| **USB/IP** | ~10ms | Excellent | High | Custom |

---

## NixOS Configuration for Receiving

```nix
# configuration.nix

# Enable v4l2loopback for virtual webcam
boot.extraModulePackages = with config.boot.kernelPackages; [
  v4l2loopback
];

boot.kernelModules = [ "v4l2loopback" ];

boot.extraModprobeConfig = ''
  options v4l2loopback devices=1 video_nr=10 card_label="Surface Webcam" exclusive_caps=1
'';

# Install streaming tools
environment.systemPackages = with pkgs; [
  ffmpeg
  obs-studio
  v4l-utils
];
```

---

## Verification Checklist

### Windows Side

- [ ] Windows 11 boots successfully
- [ ] Local account (no Microsoft account)
- [ ] Surface webcam works in Camera app
- [ ] OBS Studio installed and configured
- [ ] Streaming method configured (NDI/RTSP/MJPEG)
- [ ] Firewall allows streaming port

### NixOS Side

- [ ] v4l2loopback module loaded
- [ ] `/dev/video10` exists
- [ ] Can receive stream from Windows
- [ ] Virtual webcam works in applications

---

## Troubleshooting

### Webcam Not Detected in Windows

1. Check Device Manager for errors
2. Reinstall Surface drivers
3. Run Windows Update

### NDI Not Discovered

1. Check both machines on same network
2. Check Windows firewall (ports 5961-5969)
3. Verify NDI output enabled in OBS

### ffmpeg Can't Write to v4l2loopback

```bash
# Check device permissions
ls -la /dev/video10

# Add user to video group
sudo usermod -aG video $USER

# Reload module with correct options
sudo modprobe -r v4l2loopback
sudo modprobe v4l2loopback devices=1 video_nr=10 exclusive_caps=1
```

### High Latency

1. Use NDI instead of RTSP/MJPEG
2. Reduce resolution (720p)
3. Use wired network if possible
4. Check CPU usage on both sides

---

## Storage Optimization

After setup, disable hibernation to save space:

```powershell
# Disable hibernation (saves ~3GB)
powercfg /hibernate off

# Clear Windows Update cache
Dism.exe /online /Cleanup-Image /StartComponentCleanup
```

Expected disk usage after optimization: ~15-18GB

---

## Security Notes

| Aspect | Status | Notes |
|--------|--------|-------|
| **Encryption** | None | Zone 1 (unencrypted by design) |
| **Network** | Isolated | Only for webcam streaming |
| **Microsoft Account** | No | Local account only |
| **Telemetry** | Disabled | As much as possible |
| **Updates** | Manual | Controlled updates |

This Windows installation is intentionally minimal and isolated. It should only be used for webcam functionality and never for sensitive work.
