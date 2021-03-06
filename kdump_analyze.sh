#!/bin/bash

set -u

declare MYSELF="$(readlink -f $0)"
declare MYPATH="${MYSELF%/*}"

source "$MYPATH/lib/kdump.lib"
source "$MYPATH/lib/os.lib"

declare CORE_ARCH=""	# Coredump Arch
declare CORE_VERS=""	# Coredump Release
declare CORE_PATH=""	# Coredump path
declare CORE_LIVE=""	# 
declare DBUG_PATH=""
declare DBUG_BASE=""
declare CRSH_OPTS=""
declare CRSH_BIN="$(bin_find "crash")"
declare SHOW_HELP=""


# Prefer locally compiled version
[[ -s "$MYPATH/src/crash/bin/crash" ]] && {
	CRSH_BIN="$MYPATH/src/crash/bin/crash"
}


function show_help {
	echo "Usage: $0 [options] <memory dump>"
	echo
	echo "Options:"
	echo "  -a --arch    Define arch to be used (guessed if omited)"
	echo "  -r --release Define release version to be used (guessed if omited)"
	echo "  -c --crash   Path to the 'crash' tool to be used"
	echo "  -l --live    Analyse the live kernel"
	echo "  -q --quiet   Be quiet"
	echo "  -h --help    This help"
	echo
	echo "Help, code and contribution: http://github.com/saruspete/kdumptools"
}


eval set -- "$(getopt -o vqhla:r:c: -l verbose,quiet,help,arch:,release:,crash: -- "$@")"

while [[ -n "${1:-}" ]]; do
	case $1 in
		-a|--arch)		CORE_ARCH="$2"; shift 2 ;;
		-r|--release)	CORE_VERS="$2"; shift 2 ;;
		-c|--crash)		CRSH_BIN="$2";  shift 2 ;;
		-l|--live)		CORE_LIVE="/dev/mem" ; shift ;;
		-h|--help)		SHOW_HELP=1; shift ;;
		-q|--quiet)		CRSH_OPTS="-q"; shift ;;
		--)				shift; break ;;
		-?*)			logerror "Unknown option: '$1'"; shift ;;
		*)				break ;;
	esac
done

[[ "$SHOW_HELP" == "1" ]] && {
	show_help
	exit 0
}


# System version
[[ -z "$CRSH_BIN" ]] && {
	logwarning "Cannot find crash utility"
	
	# Try to compile it from the sources
	ask_yn "Should I retrieve and compile it (internet & compilation tools required)" && {
		declare srcpath="$MYPATH/src/crash"
		$srcpath/latest_get.sh > $srcpath/latest_get.log 2>&1 || {
			logerror "Error during retrieval of crash sources"
			logerror "Check log file $srcpath/latest_get.log for more details"
		}

		# Fetch ok, now compile it
		[[ -s "$srcpath/src/Makefile" ]] && $srcpath/latest_build.sh > $srcpath/latest_build.log 2>&1 || {
			logerror "Error during compilation of crash sources"
			logerror "Check log file $srcpath/latest_build.log for more details"
		}

		# Compilation succeeded. Use the new binary
		[[ -x "$srcpath/bin/crash" ]] && {
			CRSH_BIN="$srcpath/bin/crash"
		}
	}

	# Try to use the local package manager
	[[ -z "$CRSH_BIN" ]] && ask_yn "Should I use your package manager to install it" && {
		os_pkginstall "crash" || {
			logerror "Error during installation of the package"
		}
		CRSH_BIN="$(bin_find "crash")"
	}

	# Nothing succeeded
	[[ -z "$CRSH_BIN" ]] && {
		logerror "You can use the '-c|--crash' option to specify the tools location"
		exit 1
	}
}



CORE_PATH="${1:-$CORE_LIVE}"
[[ -z "$CORE_PATH" ]] && {
	show_help
	exit 1
}

[[ ! -e "$CORE_PATH" ]] && {
	logerror "Non existant coredump file: '$CORE_PATH'"
	exit 2
}

[[ ! -r "$CORE_PATH" ]] && {
	logerror "Unable to read coredump file: '$CORE_PATH'"
	exit 3
}

# Current kernel memory
if [[ "$CORE_PATH" =~ /dev/(mem|crash|kmem) ]]; then
	[[ -z "$CORE_VERS" ]] && CORE_VERS="$(uname -r)"
	[[ -z "$CORE_ARCH" ]] && CORE_ARCH="$(uname -m)"

	grep "kdump_live.sh" /proc/$PPID/comm >/dev/null 2>&1 || {
		logwarning "To edit your running kernel, you should start 'kdump_live.sh' instead"
	}

# Coredump file
else
	for word in $(head -n1 $CORE_PATH|strings); do
		[[ -z "$CORE_VERS" ]] && [[ "$word" =~ ^[0-9\.\-]{3,} ]] && CORE_VERS="$word"
		[[ -z "$CORE_ARCH" ]] && [[ "$word" =~ ^[xi][0-9_]+$ ]]  && CORE_ARCH="$word"
	done
fi

# Remove additionnal arch version
CORE_KERNPATH="$CORE_VERS"
CORE_VERS="${CORE_VERS%%.$CORE_ARCH}"

# Display results
[[ -n "$CORE_VERS" ]] && [[ -n "$CORE_ARCH" ]] || {
	logerror "Unable to guess arch and/or version. Specify them manually"
	logerror "arch    (--arch|-a)    '$CORE_ARCH'"
	logerror "release (--release|-r) '$CORE_VERS'"
	exit 4
}

loginfo "Guessed kernel $CORE_VERS arch $CORE_ARCH"

[[ -z "$DBUG_PATH" ]] && DBUG_PATH="$DBUG_BASE/usr/lib/debug/lib/modules/$CORE_VERS.$CORE_ARCH/vmlinux"

# Check for debuginfo
[[ ! -e "$DBUG_PATH" ]] && {
	# Didn't find it. Ask user what to do
	logwarning "Cannot find debuginfo file: $DBUG_PATH"
	if ask_yn "Should I launch 'kdump_getdbg.sh' to get debuginfo files"; then
		$MYPATH/kdump_getdbg.sh -v "$CORE_VERS" -a "$CORE_ARCH" || {
			logerror "Unable to retrieve debuginfos (return code $?)."
			logerror "You should check kdump_getdbg.sh or specify the path yourself"
			exit 10
		}
	else
		logerror "Couldn't find the debuginfo file in $DBUG_PATH"
		exit 11
	fi
}

$CRSH_BIN $CRSH_OPTS "$DBUG_PATH" "$CORE_PATH"
