import { existsSync } from "fs";
import { join } from "path";

const HOME = process.env.HOME ?? "/home/diego";

// Detect platform
const IS_TERMUX = existsSync("/data/data/com.termux.nix");

// Git root differs by platform
export const GIT_ROOT = IS_TERMUX
  ? join(HOME, "git")
  : join(HOME, "Mounts/Git");

export const UNIX_ROOT = join(GIT_ROOT, "unix");
export const CLOUD_ROOT = join(GIT_ROOT, "cloud");

export const FLAKE_TERMUX = join(UNIX_ROOT, "bb_flakes_termux");
export const FLAKE_DESKTOP = join(UNIX_ROOT, "ba_flakes_desktop");
export const FLAKE_HOST = join(UNIX_ROOT, "aa_nixos-surface_host");
export const CLOUD_HM = join(CLOUD_ROOT, "b_infra/home-manager");
export const CLOUD_DATA = IS_TERMUX
  ? join(HOME, "git/cloud-data")
  : join(HOME, "git/cloud-data");

export const PLATFORM = IS_TERMUX ? "termux" : "desktop";

export const CLOUD_VMS = [
  "gcp-proxy", "gcp-t4", "oci-mail", "oci-analytics", "oci-apps", "oci-apps-2",
];
