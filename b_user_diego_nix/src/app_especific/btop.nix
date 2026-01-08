{ config, pkgs, ... }:

# btop - system monitor

{
  programs.btop = {
    enable = true;
    settings = {
      # Color theme
      color_theme = "Default";

      # Theme background (true = use terminal background)
      theme_background = false;

      # Rounded corners
      rounded_corners = true;

      # Graph symbol to use
      graph_symbol = "braille";

      # Show graphs for processes
      shown_boxes = "cpu mem net proc";

      # Update time in milliseconds
      update_ms = 1000;

      # Process sorting
      proc_sorting = "cpu lazy";
      proc_reversed = false;
      proc_tree = false;

      # Show CPU frequency
      show_cpu_freq = true;

      # Show battery status
      show_battery = true;

      # Network interface to show
      net_auto = true;

      # Disk filter
      disks_filter = "";

      # Show I/O activity
      show_io_stat = true;
      io_mode = false;

      # Show swap
      show_swap = true;
      swap_disk = true;

      # Memory display
      mem_graphs = true;

      # Temperature display
      show_coretemp = true;
      temp_scale = "celsius";
    };
  };
}
