#!/bin/bash

# Copyright(c) 2018 Intel Corporation
# SPDX-License-Identifier: BSD-2-Clause-Patent

# Fails the script if any of the commands error (Other than if and some others)
set -e

# Function to print to stderr or stdout while stripping preceding tabs(spaces)
# If tabs are desired, use cat
print_message() {
    if [ "$1" = "stdout" ] || [ "$1" = "-" ]; then
        shift
        printf '%b\n' "${@:-Unknown Message}" | sed -e 's/^[ \t]*//'
    else
        printf '%b\n' "${@:-Unknown Message}" | sed -e 's/^[ \t]*//' >&2
    fi
}

# Convenient function to exit with message
die() {
    if [ -z "$*" ]; then
        print_message "Unknown error"
    else
        print_message "$@"
    fi
    print_message "The script will now exit."
    exit 1
}

# Function for changing directory.
cd_safe() {
    if ! cd "$1"; then
        shift
        if [ -n "$*" ]; then
            die "$@"
        else
            die "Failed cd to $1."
        fi
    fi
}

# info about self
cd_safe "$(cd "$(dirname "$0")" > /dev/null 2>&1 && pwd)"

# Help message
echo_help() {
    cat << EOF
Usage: $0 [OPTION] ... -- [OPTIONS FOR CMAKE]
-a, --all, all          Builds release and debug
    --cc, cc=*          Set C compiler [$CC]
    --clean, clean      Remove build and Bin folders
    --debug, debug      Build debug
    --shared, shared    Build shared libs
-x, --static, static    Build static libs
-i, --install, install  Install build [Default release]
-p, --prefix, prefix=*  Set installation prefix
    --release, release  Build release
Example usage:
    build.sh -xi debug -- -G"Ninja"
    build.sh all cc=clang static release install
EOF
}

# Usage: build <release|debug> "$@"
build() (
    local build_type match
    while [ -n "$*" ]; do
        match=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        case "$match" in
        release) build_type="Release" && shift ;;
        debug) build_type="Debug" && shift ;;
        *) break ;;
        esac
    done

    mkdir -p ${build_type:-Release} > /dev/null 2>&1
    cd_safe ${build_type:-Release}
    [ -f CMakeCache.txt ] && rm CMakeCache.txt
    [ -d CMakeFiles ] && rm -rf CMakeFiles
    [ -f Makefile ] && rm Makefile
    cmake ../../.. -DCMAKE_BUILD_TYPE="${build_type:-Release}" "${CMAKE_EXTRA_FLAGS[@]}" "$@"

    # Compile the Library
    if [ -f Makefile ]; then
        make -j "$jobs"
    else
        cmake --build . --config "${build_type:-Release}"
    fi
    cd_safe ..
)

check_executable() {
    local print_exec command_to_check
    while true; do
        case "$1" in
        -p)
            print_exec=y
            shift
            ;;
        *) break ;;
        esac
    done
    command_to_check="$1"
    if command -v "$command_to_check" > /dev/null 2>&1; then
        [ -n "$print_exec" ] && command -v "$command_to_check"
        return 0
    else
        if [ $# -gt 1 ]; then
            shift
            local hints
            hints=("$@")
            for d in "${hints[@]}"; do
                if [ -e "$d/$command_to_check" ]; then
                    [ -n "$print_exec" ] && echo "$d/$command_to_check"
                    return 0
                fi
            done
        fi
        return 127
    fi
}

install_build() {
    local build_type sudo
    build_type="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    check_executable sudo && sudo -v > /dev/null 2>&1 && sudo=sudo
    [ -d "${build_type:-release}" ] &&
        cd_safe "${build_type:-release}" "Unable to find the build folder. Did the build command run?"
    $sudo cmake --build . --target install --config "${build_type:-release}" ||
        die "Unable to run install"
    cd_safe ..
}

parse_options() {
    while [ -n "$*" ]; do
        case $1 in
        help)
            echo_help
            exit
            ;;
        cc=*)
            if check_executable "${1#*=}"; then
                CC="$(check_executable -p "${1#*=}")"
                export CC
            fi
            shift
            ;;
        clean)
            for d in *; do
                [ -d "$d" ] && rm -rf "$d"
            done
            for d in ../../Bin/*; do
                [ -d "$d" ] && rm -rf "$d"
            done
            exit
            ;;
        debug) build_debug=y && shift ;;
        build_shared) CMAKE_EXTRA_FLAGS=("${CMAKE_EXTRA_FLAGS[@]}" "-DBUILD_SHARED_LIBS=ON") && shift ;;
        build_static) CMAKE_EXTRA_FLAGS=("${CMAKE_EXTRA_FLAGS[@]}" "-DBUILD_SHARED_LIBS=OFF") && shift ;;
        install) build_install=y && shift ;;
        prefix=*) CMAKE_EXTRA_FLAGS=("${CMAKE_EXTRA_FLAGS[@]}" "-DCMAKE_INSTALL_PREFIX=${1#*=}") && shift ;;
        release) build_release=y && shift ;;
        verbose) CMAKE_EXTRA_FLAGS=("${CMAKE_EXTRA_FLAGS[@]}" "-DCMAKE_VERBOSE_MAKEFILE=1") && shift ;;
        esac
    done
}

# Defines
uname=$(uname -a)
if [ -z "$CC" ] && [ "${uname:0:5}" != "MINGW" ]; then
    if check_executable icc "/opt/intel/bin"; then
        CC=$(check_executable -p icc "/opt/intel/bin")
    elif check_executable gcc; then
        CC=$(check_executable -p gcc)
    elif check_executable clang; then
        CC=$(check_executable -p clang)
    else
        CC=$(check_executable -p cc)
    fi
    export CC
fi

if [ -z "$jobs" ]; then
    if getconf _NPROCESSORS_ONLN > /dev/null 2>&1; then
        jobs=$(getconf _NPROCESSORS_ONLN)
    elif check_executable nproc; then
        jobs=$(nproc)
    elif check_executable sysctl; then
        jobs=$(sysctl -n hw.ncpu)
    else
        jobs=2
    fi
fi

if [ -z "$*" ]; then
    build_release=y
else
    while [ -n "$*" ]; do
        match=""
        # Handle --* based args
        if [ "${1:0:2}" = "--" ]; then
            # Stop on "--", pass the rest to cmake
            [ -z "${1:2}" ] && shift && break
            match=$(echo "${1:2}" | tr '[:upper:]' '[:lower:]')
            case "$match" in
            help)
                parse_options help
                shift
                ;;
            all)
                parse_options debug release
                shift
                ;;
            cc)
                parse_options cc="$2"
                shift 2
                ;;
            clean)
                parse_options clean
                shift
                ;;
            debug)
                parse_options debug
                shift
                ;;
            install)
                parse_options install
                shift
                ;;
            prefix)
                parse_options prefix="$2"
                shift 2
                ;;
            release)
                parse_options release
                shift
                ;;
            shared)
                parse_options build_shared
                shift
                ;;
            static)
                parse_options build_static
                shift
                ;;
            verbose)
                parse_options verbose
                shift
                ;;
            *) die "Error, unknown option: $1" ;;
            esac
        # Handle -* based args, one letter at a time
        elif [ "${1:0:1}" = "-" ]; then
            i=1
            opt=""
            while [ $i -lt ${#1} ]; do
                opt=$(echo "${1:i:1}" | tr '[:upper:]' '[:lower:]')
                case "$opt" in
                h) parse_options help ;;
                a) parse_options all && i=$((i + 1)) ;;
                i) parse_options install && i=$((i + 1)) ;;
                p) parse_options prefix="$1" && i=$((i + 1)) ;;
                x) parse_options build_static && i=$((i + 1)) ;;
                v) parse_options verbose && i=$((i + 1)) ;;
                *) die "Error, unknown option: -$opt" ;;
                esac
                i=$((i + 1))
            done
            shift
        # Handle single word args
        else
            match=$(echo "$1" | tr '[:upper:]' '[:lower:]')
            case "$match" in
            all)
                parse_options release debug
                shift
                ;;
            cc=*)
                parse_options cc="${1#*=}"
                shift
                ;;
            clean)
                parse_options clean
                shift
                ;;
            debug)
                parse_options debug
                shift
                ;;
            help)
                parse_options help
                shift
                ;;
            install)
                parse_options install
                shift
                ;;
            prefix=*)
                parse_options prefix="${1#*=}"
                shift
                ;;
            shared)
                parse_options build_shared
                shift
                ;;
            static)
                parse_options build_static
                shift
                ;;
            release)
                parse_options release
                shift
                ;;
            verbose)
                parse_options verbose
                shift
                ;;
            end) exit ;;
            *) die "Error, unknown option: $1" ;;
            esac
        fi
    done
fi

[[ ":$PATH:" != *":/usr/local/bin:"* ]] && PATH="$PATH:/usr/local/bin"

if [ "$build_debug" = "y" ] && [ "$build_release" = "y" ]; then
    build release "$@"
    build debug "$@"
elif [ "$build_debug" = "y" ]; then
    build debug "$@"
else
    build release "$@"
fi

if [ -n "$build_install" ]; then
    if [ -n "$build_release" ]; then
        install_build release
    elif [ -n "$build_debug" ]; then
        install_build debug
    else
        build release "$@"
        install_build release
    fi
fi
