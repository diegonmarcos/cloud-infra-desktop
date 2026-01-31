#!/bin/zsh
# =============================================================================
# ZSH C DEVELOPMENT FUNCTIONS - Compile, debug, and test C code
# Source: shell/zsh/functions-c-dev.zsh
# =============================================================================

# Path to git projects (customize as needed)
path_to_my_git="${path_to_my_git:-/home/diego/Documents/Git/}"

# Colors for output
local rst="\e[0m"
local red="\e[1;31m"
local green="\e[1;32m"
local yellow="\e[1;33m"

# =============================================================================
# HELP
# =============================================================================
myhelp_c() {
    printf "\n\n\n$green##########################"
    printf "\n$green####### C DEV HELP #######"
    printf "\n$green##########################$rst\n"
    printf "\n\e[4mFunctions List:\e[0m"
    printf "\n * c, cx, cv, cdb        - Compile without library"
    printf "\n * cl, clx, clv, cldb    - Compile with mylibc"
    printf "\n * code_cleaner          - Clean code formatting"
    printf "\n * clean_debuger         - Remove debug statements\n"
    printf "\n\e[4mSyntaxes:\e[0m"
    printf "\n Compile and Execute:"
    printf "\n\e[1m  cx <source.c> [args...]\e[0m\n"
    printf "\n Compile and Valgrind:"
    printf "\n\e[1m  cv <source.c> {test_name|-} {infile|-} [args...]\e[0m\n"
    printf "\n Compile and Debug:"
    printf "\n\e[1m  cldb <source.c> [args...]\e[0m\n"
}

# =============================================================================
# COMPILERS (no library)
# =============================================================================

# Compile file
c() {
    clang -g3 "$@" -o "$(basename "$1" .c).out"
}

# Compile and execute
cx() {
    clang -g3 "$1" -o "$(basename "$1" .c).out"
    ./"$(basename "$1" .c).out" "${@:2}"
}

# Compile and run with Valgrind
cv() {
    if [[ "$1" = "help" ]]; then
        echo -e "\n${yellow}##########################"
        echo -e "####### CV HELP ##########"
        echo -e "##########################${rst}\n"
        echo -e "\e[4mSyntax:\e[0m"
        echo -e "\e[1mcv <source.c> {test_name|-} {infile_stdin|-} [args...]\e[0m\n"
        echo -e "\e[4mExamples:\e[0m"
        echo -e " cv file.c - - arg1"
        echo -e " cv file.c test1 log/input.txt arg1 arg2"
        return
    fi

    local source_file=$1
    local test_name=$2
    [[ "$2" == '-' ]] && test_name=$4
    local infile_stdin="$3"
    local args="${@:4}"

    mkdir -p log
    local valg_filename="log/valgrind_$test_name.log"
    local outfile_stdout="log/outfile_$test_name.log"
    local program="./$(basename "$source_file" .c).out"

    local valg_flags="--leak-check=full --show-leak-kinds=all --track-origins=yes -s --track-fds=yes --trace-children=yes"

    # Compile
    clang -g3 $source_file -o "$(basename "$source_file" .c).out"

    # Run Valgrind
    if [[ "$infile_stdin" == '-' ]]; then
        valgrind $valg_flags --log-file="$valg_filename" $program $args > "$outfile_stdout" 2>&1
    else
        valgrind $valg_flags --log-file="$valg_filename" $program $args < "$infile_stdin" > "$outfile_stdout" 2>&1
    fi

    # Append info to log
    echo -e "\n== PROGRAM INPUT ==\n$args\n" >> $valg_filename
    echo -e "\n== PROGRAM OUTPUT ==\n" >> $valg_filename
    cat $outfile_stdout >> $valg_filename

    # Print summary
    echo -e "\n\n${red}##########################"
    echo -e "##### Valgrind Test ######"
    echo -e "##########################${rst}\n"
    echo -e "${red}=== HEAP SUMMARY ===${rst}"
    grep -A 4 "HEAP SUMMARY" $valg_filename
    echo -e "\n${red}=== LEAK SUMMARY ===${rst}"
    grep -A 7 "LEAK SUMMARY" $valg_filename
    echo -e "\n${red}=== FILE DESCRIPTORS ===${rst}"
    grep -A 0 "FILE DESCRIPTORS" $valg_filename
    echo -e "\n${red}=== ERRORS ===${rst}"
    grep -B 1 -A 2 "at 0x" $valg_filename
}

# =============================================================================
# COMPILERS WITH LIBRARY (mylibc)
# =============================================================================

# Compile with library
cl() {
    local lib_header="${path_to_my_git}mylibs/mylibc/inc"
    local lib_addss="${path_to_my_git}mylibs/mylibc"
    local lib_name="mylibc"
    clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "$(basename "$1" .c).out"
}

# Compile with library and execute
clx() {
    local lib_header="${path_to_my_git}mylibs/mylibc/inc"
    local lib_addss="${path_to_my_git}mylibs/mylibc"
    local lib_name="mylibc"
    clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "$(basename "$1" .c).out"
    ./"$(basename "$1" .c).out" "${@:2}"
}

# Compile with library and Valgrind
clv() {
    local lib_header="${path_to_my_git}mylibs/mylibc/inc"
    local lib_addss="${path_to_my_git}mylibs/mylibc"
    local lib_name="mylibc"
    local valg_args="--leak-check=full --show-leak-kinds=all --track-origins=yes -s --log-file=valgrind_output.txt"
    local program="./$(basename "$1" .c).out"

    clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "$(basename "$1" .c).out"
    valgrind $valg_args $program "${@:2}" > /dev/null 2>&1
    grep "$1": valgrind_output.txt
}

# =============================================================================
# DEBUGGERS
# =============================================================================

_print_lldb_help() {
    echo -e "\n################################################################"
    echo -e "##### LLDB CHEATSHEET ##########################################"
    echo -e "# b main         - Set breakpoint at main"
    echo -e "# b <func>       - Set breakpoint at function"
    echo -e "# r              - Run program"
    echo -e "# n              - Step over (next line)"
    echo -e "# s              - Step into function"
    echo -e "# finish         - Step out of function"
    echo -e "# c              - Continue execution"
    echo -e "# v              - View local variables"
    echo -e "# bt             - Backtrace (call stack)"
    echo -e "# gui            - Launch GUI mode"
    echo -e "################################################################\n"
}

_print_gdb_help() {
    echo -e "\n################################################################"
    echo -e "##### GDB CHEATSHEET ###########################################"
    echo -e "# b main         - Set breakpoint at main"
    echo -e "# r              - Run program"
    echo -e "# n              - Step over (next)"
    echo -e "# s              - Step into"
    echo -e "# finish         - Step out"
    echo -e "# c              - Continue"
    echo -e "# info locals    - View local variables"
    echo -e "# info args      - View arguments"
    echo -e "# bt             - Backtrace"
    echo -e "# tui enable     - Enable TUI mode"
    echo -e "################################################################\n"
}

# Debug without library (lldb)
cdb() {
    _print_lldb_help
    local output_name="$(basename "$1" .c).debug.out"
    clang -g3 "$1" -o "${output_name}"
    lldb ./"${output_name}" "${@:2}" -o "b main" -o "run" -o "v"
}

# Debug with library (lldb)
cldb() {
    _print_lldb_help
    local lib_header="${path_to_my_git}mylibs/mylibc/inc"
    local lib_addss="${path_to_my_git}mylibs/mylibc"
    local lib_name="mylibc"
    local output_name="$(basename "$1" .c).debug.out"
    clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "${output_name}"
    lldb ./"${output_name}" "${@:2}" -o "b main" -o "run" -o "v"
}

# Debug with library (gdb)
cldbg() {
    _print_gdb_help
    local lib_header="${path_to_my_git}mylibs/mylibc/inc"
    local lib_addss="${path_to_my_git}mylibs/mylibc"
    local lib_name="mylibc"
    local output_name="$(basename "$1" .c).debug.out"
    gcc -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "${output_name}"
    gdb ./"${output_name}" "${@:2}" -ex "b main" -ex "run" -ex "info locals"
}

# =============================================================================
# CODE UTILITIES
# =============================================================================

code_cleaner() {
    local folder="${path_to_my_git}libft_xtend/ft_mylib/src/9_Quality_Assurance/Code_Cleaner"
    "$folder/clean_code.sh" "$@"
}

clean_debuger() {
    local folder="${path_to_my_git}mylibs/mytools/1_coding/make_utils"
    "$folder/clean_debuger.sh" "$@"
}

file_consol_lns() {
    local folder="${path_to_my_git}mylibs/mytools/1_coding/make_utils"
    "$folder/files_lns.sh" "$@"
}
