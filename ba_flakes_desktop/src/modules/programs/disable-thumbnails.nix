# programs/disable-thumbnails.nix — trim Dolphin's thumbnail plugin list.
# 2026-08-02: cpu.pressure some avg10 sat at 53% (load 16.4) on this 8GB box.
# Top consumers were 7 Dolphin thumbnail kioworkers at ~40% CPU each (~240%
# total), 113MB RSS each — spawned by kio/thumbnail.so re-decoding previews
# (video frames, RAW, EXR, Blender files) in whatever folder Dolphin had
# open. Killing them dropped PSI to 18% immediately, but they respawn within
# seconds, so killing is not a fix. Same class of problem as
# ./disable-baloo.nix: a background KDE convenience feature that's cheap in
# the common case but pathological on this machine's file mix.
#
# Fix: keep the cheap thumbnailers (plain images, fonts, dirs, cursors) and
# drop the ones that spin up an external decoder per file — ffmpeg for
# video, RAW/EXR image decoders, Blender's own preview renderer, etc. Also
# cap the file size Dolphin will bother thumbnailing at all, so a stray
# multi-GB file in a watched folder can't trigger a decode.
{ config, pkgs, lib, ... }:
{
  # NB: this shares programs.plasma.configFile."dolphinrc" with
  # ./modules/desktop/plasma.nix (General/VersionControl/Terminal Panel
  # groups) and "kdeglobals" (Colors:*/General groups). Different modules
  # writing different *groups* of the same managed file merge fine through
  # the normal NixOS attrset merge — this is not the baloofilerc case, where
  # two different write *mechanisms* (home.file vs programs.plasma) fought
  # over the same file. Here it's all programs.plasma.configFile, so there's
  # exactly one writer either way.
  programs.plasma.configFile = {
    "dolphinrc"."PreviewSettings" = {
      # Cut from the default 25-plugin list down to thumbnailers that just
      # decode an existing embedded/simple format — no transcoding, no
      # external renderer. Dropped: ffmpegthumbs, blenderthumbnail,
      # rawthumbnail, exrthumbnail, mltpreview, gsthumbnail (video/3D/RAW/
      # PostScript decoders, the actual CPU cost), totem, evince,
      # windowsexethumbnail, appimagethumbnail, kraorathumbnail,
      # comicbookthumbnail, djvuthumbnail, mobithumbnail, ebookthumbnail
      # (each shells out to or links a heavyweight parser for formats we
      # rarely browse by thumbnail anyway), plus windowsimagethumbnail
      # (niche .ico/.exe icon extraction, redundant with imagethumbnail for
      # real images) and gnome-font-viewer (duplicates fontthumbnail via an
      # external GTK tool instead of an in-process decoder).
      Plugins = "audiothumbnail,cursorthumbnail,directorythumbnail,fontthumbnail,imagethumbnail,jpegthumbnail,opendocumentthumbnail,svgthumbnail";
    };
    # KIO's PreviewJob reads [PreviewSettings] MaximumSize from kdeglobals
    # (previewjob.cpp, default 5*1024*1024 = 5MB) — the byte cutoff above
    # which no thumbnailer runs regardless of plugin. Pin it explicitly
    # rather than relying on the implicit default, so a stray multi-GB file
    # can't get handed to a thumbnailer at all.
    "kdeglobals"."PreviewSettings" = {
      MaximumSize = 5242880; # 5MB, matches KIO's documented default
      # EnableRemoteFolderThumbnail already false in the live config —
      # not redeclared here to avoid a second writer for a kdeglobals key
      # already covered by whatever set it (plasma.nix's kdeglobals groups
      # don't touch PreviewSettings, so this is the only PreviewSettings
      # writer; left as a note in case that changes).
    };
  };

  # Apply immediately rather than only on the next Dolphin restart. Same
  # pattern as ./disable-baloo.nix's balooctl call and the kwriteconfig6
  # calls in ./modules/desktop/plasma.nix (kscreenlockerrc, PowerDevil):
  # write the live file directly, after the plasma-manager config write
  # (writeBoundary) so it doesn't get clobbered by it, non-fatal if the
  # tool or files aren't there yet.
  home.activation.trimDolphinThumbnails = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    KW=${pkgs.kdePackages.kconfig}/bin/kwriteconfig6
    $DRY_RUN_CMD $KW --file dolphinrc --group PreviewSettings \
      --key Plugins "audiothumbnail,cursorthumbnail,directorythumbnail,fontthumbnail,imagethumbnail,jpegthumbnail,opendocumentthumbnail,svgthumbnail" 2>/dev/null || true
    $DRY_RUN_CMD $KW --file kdeglobals --group PreviewSettings \
      --key MaximumSize 5242880 2>/dev/null || true
  '';
}
