# Surface Pro 8 hardware: kernel, CPU, firmware, power management
{ config, lib, pkgs, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # LINUX-SURFACE KERNEL
  # ═══════════════════════════════════════════════════════════════════════════
  # CRITICAL: Surface Pro 8 Type Cover keyboard requires linux-surface kernel
  # The mainline kernel lacks surface_aggregator_hub module needed for SAM

  hardware.microsoft-surface = {
    # Use stable linux-surface kernel (latest patched release)
    # Options: "stable" (latest) or "longterm" (LTS, default)
    kernelVersion = "stable";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE
  # ═══════════════════════════════════════════════════════════════════════════

  # Surface Pro 8 has Intel Tiger Lake
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware for WiFi, etc.
  hardware.enableRedistributableFirmware = true;

  # Power management - no CPU cap, full performance
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # Platform
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ═══════════════════════════════════════════════════════════════════════════
  # PEN STASH PROBE FIX (linux-surface#1845)
  # ═══════════════════════════════════════════════════════════════════════════
  # Device 01:15:02:02:00 is the "pen stash" slot on Surface Flex Keyboard.
  # Type Cover lacks this device, so surface_hid probe gets 0-byte descriptor,
  # returns -EPROTO (error -71), retries for ~2 min, disrupts entire HID stack
  # causing trackpad click freezes.

  # Option 2 (active): udev rule — prevent surface_hid from binding to pen stash
  services.udev.extraRules = ''
    SUBSYSTEM=="surface_aggregator_clients", ATTR{modalias}=="ssam:d01c15t02i02f00", ENV{MODALIAS}="", ATTR{driver_override}="(none)"
  '';

  # Option 1 (pending): kernel patch — proper fix, return -ENODEV for empty descriptors
  # Uncomment when ready for kernel rebuild (~2h). Safe to use alongside udev rule.
  # boot.kernelPatches = [{
  #   name = "surface-hid-enodev-for-empty-descriptor";
  #   patch = pkgs.writeText "surface-hid-empty-descriptor.patch" ''
  #     --- a/drivers/hid/surface-hid/surface_hid.c
  #     +++ b/drivers/hid/surface-hid/surface_hid.c
  #     @@ ssam_hid_get_descriptor
  #      	if (offset >= len) {
  #     -		dev_err(&sdev->dev, "unexpected descriptor length: got %zu, expected %zu\n",
  #     -			offset, len);
  #     -		return -EPROTO;
  #     +		if (offset == 0) {
  #     +			dev_info(&sdev->dev, "empty descriptor, device not present\n");
  #     +			return -ENODEV;
  #     +		} else {
  #     +			dev_err(&sdev->dev, "unexpected descriptor length: got %zu, expected %zu\n",
  #     +				offset, len);
  #     +			return -EPROTO;
  #     +		}
  #      	}
  #   '';
  # }];
}
