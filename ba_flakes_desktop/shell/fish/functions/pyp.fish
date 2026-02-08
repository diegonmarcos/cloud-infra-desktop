function pyp --description 'Install/Run package with optional sudo path fix'
    # 1. Check for minimum arguments
    if test (count $argv) -lt 1
        echo "Error: Need at least one argument: [Package_Name] or [sudo Package_Name]."
        return 1
    end

    # Variables
    set -l is_sudo_mode false
    set -l target_package ""
    set -l extra_args ""

    # --- Mode Detection ---
    if test $argv[1] = "sudo"
        # MODE: SUDO (e.g., pyp sudo ps_mem)
        if test (count $argv) -lt 2
            echo "Error: 'pyp sudo' requires a package name: pyp sudo [package]."
            return 1
        end
        set is_sudo_mode true
        set target_package $argv[2]
        # Any arguments coming AFTER the package name (e.g., -p 1234)
        set extra_args $argv[3..-1]
    else
        # MODE: STANDARD (e.g., pyp ps_mem)
        set target_package $argv[1]
        # Any arguments coming AFTER the package name
        set extra_args $argv[2..-1]
    end

    # 2. Change Directory
    cd ~/poetry_venv_1

    # 3. INSTALL the package (Always runs)
    echo "Installing package: $target_package..."
    poetry add "$target_package"

    # 4. RUN the command
    echo "Running command..."

    if test $is_sudo_mode = "true"
        # --- SUDO PATH FIX ---

        # Get the absolute path dynamically from the Venv
        set -l abs_path (poetry run which $target_package 2>/dev/null)

        if test -z "$abs_path"
            echo "Error: Could not find executable '$target_package' in Venv."
            return 1
        end

        # Join any extra arguments into a single string with spaces
        set -l args_string (string join " " $extra_args)

        # Build the final command string: sudo "/path/to/exe" arg1 arg2
        set -l command_string "sudo \"$abs_path\" $args_string"

        echo "Executing with SUDO path fix: sh -c '$command_string'"

        # Execute via sh -c to handle sudo correctly
        poetry run sh -c "$command_string"
    else
        # --- STANDARD EXECUTION ---
        poetry run $target_package $extra_args
    end
end
