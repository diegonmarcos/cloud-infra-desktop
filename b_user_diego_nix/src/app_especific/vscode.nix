{ config, pkgs, ... }:

# VSCode / Cursor settings
# NOTE: wakatime.apiKey is sensitive - consider using sops-nix or agenix for secrets

{
  programs.vscode = {
    enable = true;
    package = pkgs.vscode;

    userSettings = {
      # Git
      "git.enableSmartCommit" = true;
      "git.autofetch" = true;
      "git.confirmSync" = false;
      "git.ignoreRebaseWarning" = true;
      "git.openRepositoryInParentFolders" = "always";

      # Explorer
      "explorer.confirmDragAndDrop" = false;
      "explorer.confirmPasteNative" = false;

      # 42 Header
      "42header.email" = "dinepomu@student.42berlin.de";
      "42header.username" = "dinepomu";

      # Editor
      "editor.detectIndentation" = false;
      "editor.insertSpaces" = false;
      "editor.largeFileOptimizations" = false;
      "editor.minimap.enabled" = false;
      "editor.unicodeHighlight.nonBasicASCII" = false;
      "editor.inlineSuggest.syntaxHighlightingEnabled" = true;

      # PSI Header templates
      "psi-header.changes-tracking" = {};
      "psi-header.templates" = [
        {
          language = "*";
          template = [
            "************************************************************************** *"
            "@syntax:"
            "@brief:"
            "@param:"
            "@return:"
            ""
            "@note:"
            ""
            "@file: <<filename>>"
            "@author: Diego <dinepomu@student.42>"
            "@created: <<filecreated('DD/MMM/YYYY hh:mm')>>"
            "@updated: <<dateformat('DD/MMM/YYYY hh:mm')>>"
            "************************************************************************** *"
          ];
        }
      ];
      "psi-header.variables" = [];

      # Window
      "window.customTitleBarVisibility" = "auto";
      "window.titleBarStyle" = "native";

      # Workbench
      "workbench.editor.empty.hint" = "hidden";
      "workbench.editor.doubleClickTabToToggleEditorGroupSizes" = "off";
      "workbench.editor.centeredLayoutAutoResize" = false;
      "workbench.editor.pinnedTabsOnSeparateRow" = true;
      "workbench.editor.restoreViewState" = false;
      "workbench.editor.tabSizing" = "fixed";
      "workbench.editor.wrapTabs" = true;
      "workbench.activityBar.location" = "top";
      "workbench.panel.alignment" = "justify";
      "workbench.panel.defaultLocation" = "bottom";
      "workbench.startupEditor" = "none";

      # Terminal
      "terminal.integrated.tabs.location" = "left";

      # Diff Editor
      "diffEditor.maxComputationTime" = 0;

      # Files
      "files.exclude" = {
        "**/.git" = false;
      };

      # Clang-tidy
      "clang-tidy.checks" = [
        "-*"
        "-cert-err33-c"
        "-clang-analyzer-*"
        "-cppcoreguidelines-*"
        "-performance-*"
        "-readability-*"
        "-hicpp-*"
        "cert-*"
        "bugprone-*"
        "modernize-*"
        "misc-*"
      ];

      # AI/Copilot
      "github.copilot.nextEditSuggestions.enabled" = true;
      "gitlens.ai.model" = "vscode";
      "gitlens.ai.vscode.model" = "copilot:gpt-4.1";

      # Chat
      "chat.sendElementsToChat.attachCSS" = false;
      "chat.sendElementsToChat.attachImages" = false;
      "chat.sendElementsToChat.enabled" = false;

      # Languages
      "svelte.enable-ts-plugin" = true;
      "python.defaultInterpreterPath" = "/bin/python3";

      # WakaTime - SENSITIVE: Use secrets management!
      # "wakatime.apiKey" = "YOUR_API_KEY_HERE";
    };

    keybindings = [
      {
        key = "ctrl+alt+y";
        command = "42header.insertHeader";
        when = "editorTextFocus";
      }
      {
        key = "ctrl+alt+h";
        command = "-42header.insertHeader";
        when = "editorTextFocus";
      }
      {
        key = "ctrl+shift+t";
        command = "editor.action.insertSnippet";
        when = "editorTextFocus";
        args = {
          snippet = "                                                                                ";
        };
      }
      {
        key = "ctrl+s ctrl+1";
        command = "workbench.action.files.save";
      }
      {
        key = "ctrl+s";
        command = "-workbench.action.files.save";
      }
      {
        key = "ctrl+s";
        command = "workbench.action.files.saveAll";
      }
      {
        key = "ctrl+r";
        command = "workbench.action.files.revert";
        when = "editorTextFocus";
      }
      {
        key = "shift+enter";
        command = "workbench.action.terminal.sendSequence";
        args = {
          text = "\\\r\n";
        };
        when = "terminalFocus";
      }
    ];

    extensions = with pkgs.vscode-extensions; [
      # Add your extensions here
      # ms-python.python
      # ms-vscode.cpptools
      # svelte.svelte-vscode
    ];
  };
}
