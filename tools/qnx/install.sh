#!/bin/sh
# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Installs PowerShell on QNX Neutrino from an install tree made by
# tools/qnx/build.sh, which places this script at the top of the tree.
#
# Usage: install.sh [options]
#
#   --prefix DIR     where to install (default: /opt/powershell)
#   --bindir DIR     where the pwsh link goes (default: /usr/bin)
#   --login-shell    also list pwsh in /etc/shells, so it can be a login shell
#   --uninstall      remove what an earlier install made
#   --force          go ahead even if PowerShell is running from this tree or
#                    the install directory (see below)
#
# Running it again replaces an earlier install with this tree. It never
# replaces a pwsh or an install directory it did not make. --uninstall leaves
# /etc/shells as it found it: it removes only its own line, and the file only
# if --login-shell created it and nothing else is in it.
#
# It stops, before reading or writing anything, while a PowerShell runs from
# this tree or from the install directory, as a precaution: QNX 6.5 can hang
# as a whole when a program reads into memory it has not touched while one of
# its own threads pages a file in (procnto and the disk driver wait on each
# other; see docs/qnx/README.md). Whether another program reading the file, as
# installing reads every file of this tree, can trigger it has not been shown.
# A program started by a relative path cannot be placed, so it stops for that
# too; --force goes ahead anyway.

set -eu

prefix=/opt/powershell
bindir=/usr/bin
login_shell=0
uninstall=0
force=0
marker=.installed-by-install.sh
# Beside the marker when --login-shell created /etc/shells.
shells_marker=.created-etc-shells

usage() {
	sed -n '/^# Usage/,/^$/s/^# \{0,1\}//p' "$0" >&2
	exit 2
}

fail() {
	echo "install.sh: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case $1 in
	--prefix) [ $# -ge 2 ] || usage; prefix=$2; shift ;;
	--bindir) [ $# -ge 2 ] || usage; bindir=$2; shift ;;
	--login-shell) login_shell=1 ;;
	--uninstall) uninstall=1 ;;
	--force) force=1 ;;
	-h|--help) usage ;;
	*) usage ;;
	esac
	shift
done

case $prefix in /*) ;; *) fail "--prefix must be an absolute path" ;; esac
case $bindir in /*) ;; *) fail "--bindir must be an absolute path" ;; esac
prefix=${prefix%/}
bindir=${bindir%/}
[ -n "$prefix" ] || fail "--prefix cannot be /"

link=$bindir/pwsh
target=$prefix/pwsh/pwsh

# The link is ours if it points into an install this script made.
link_is_ours() {
	[ -L "$link" ] && [ "$(ls -l "$link" | sed 's/.* -> //')" = "$target" ]
}

check_link() {
	if [ -e "$link" ] || [ -L "$link" ]; then
		link_is_ours || fail "$link exists and is not a link to $target; not replacing it"
	fi
}

check_prefix() {
	if [ -e "$prefix" ] && [ ! -f "$prefix/$marker" ]; then
		if [ -d "$prefix" ] && [ -z "$(ls -a "$prefix" | grep -v -e '^\.$' -e '^\.\.$')" ]; then
			return
		fi
		fail "$prefix exists and was not made by install.sh; not replacing it"
	fi
}

remove_shell() {
	if [ -f /etc/shells ] && grep -qx "$link" /etc/shells; then
		grep -vx "$link" /etc/shells > /etc/shells.new || true
		cat /etc/shells.new > /etc/shells
		rm -f /etc/shells.new
		echo "removed $link from /etc/shells"
	fi
	if [ -f "$prefix/$shells_marker" ] && [ -f /etc/shells ] && [ ! -s /etc/shells ]; then
		rm -f /etc/shells
		echo "removed /etc/shells, which the install created"
	fi
}

# The file a path names, its symbolic links followed.
resolve() {
	p=$1
	n=0
	while [ -L "$p" ] && [ $n -lt 20 ]; do
		t=$(ls -l "$p" | sed 's/.* -> //')
		case $t in
		/*) p=$t ;;
		*) p=$(dirname "$p")/$t ;;
		esac
		n=$((n + 1))
	done
	d=$(cd "$(dirname "$p")" 2>/dev/null && pwd) || return 1
	echo "$d/$(basename "$p")"
}

# Lists the PowerShell processes that run from one of the given directories,
# or whose start cannot be placed. pidin names a program by the path it was
# started with, without its leading slash. (A function of its own: QNX 6.5's
# sh cannot parse a case statement inside $(...).)
list_running() {
	pidin -F "%a %n" 2>/dev/null | while read -r pid name; do
		case ${name##*/} in
		pwsh | qnxhost) ;;
		*) continue ;;
		esac
		case $name in
		./* | ../*) file= ;;
		*) file=$(resolve "/$name") || file= ;;
		esac
		if [ -z "$file" ] || [ ! -e "$file" ]; then
			echo "  pid $pid, $name: started by a relative path, so not known where from"
			continue
		fi
		for dir in "$@"; do
			if [ "$file" = "$dir/pwsh/pwsh" ] || [ "$file" = "$dir/bin/qnxhost" ]; then
				echo "  pid $pid, $name: runs from $dir"
				break
			fi
		done
	done
}

# Stops while a PowerShell runs from one of the given directories; see the
# comment at the top.
check_running() {
	[ $force = 0 ] || return 0
	command -v pidin >/dev/null 2>&1 || return 0
	found=$(list_running "$@")
	[ -n "$found" ] || return 0
	echo "install.sh: PowerShell is running:" >&2
	echo "$found" >&2
	fail "stop it first, or use --force (on QNX 6.5, reading files a running program pages in can hang the whole system)"
}

if [ $uninstall = 1 ]; then
	if [ -d "$prefix" ]; then
		check_running "$(cd "$prefix" && pwd)"
	fi
	check_link
	check_prefix
	remove_shell
	if [ -L "$link" ]; then
		rm -f "$link"
		echo "removed $link"
	fi
	if [ -e "$prefix" ]; then
		rm -rf "$prefix"
		echo "removed $prefix"
	fi
	exit 0
fi

tree=$(cd "$(dirname "$0")" && pwd)
if [ -d "$prefix" ]; then
	check_running "$tree" "$(cd "$prefix" && pwd)"
else
	check_running "$tree"
fi
[ -f "$tree/pwsh.props" ] && [ -x "$tree/pwsh/pwsh" ] ||
	fail "$tree is not a PowerShell install tree (no pwsh.props or pwsh/pwsh)"

check_link
check_prefix

if [ "$tree" != "$prefix" ]; then
	# Copy next to the old install first, then swap, so that a failed copy
	# leaves the old install in place.
	mkdir -p "$(dirname "$prefix")"
	rm -rf "$prefix.new"
	mkdir "$prefix.new"
	(cd "$tree" && tar cf - .) | (cd "$prefix.new" && tar xf -)
	: > "$prefix.new/$marker"
	if [ -f "$prefix/$shells_marker" ]; then
		: > "$prefix.new/$shells_marker"
	fi
	rm -rf "$prefix"
	mv "$prefix.new" "$prefix"
	echo "installed $tree to $prefix"
else
	: > "$prefix/$marker"
fi

mkdir -p "$bindir"
rm -f "$link"
ln -s "$target" "$link"
echo "linked $link to $target"

if [ $login_shell = 1 ]; then
	if [ ! -e /etc/shells ]; then
		: > "$prefix/$shells_marker"
	fi
	if [ ! -f /etc/shells ] || ! grep -qx "$link" /etc/shells; then
		echo "$link" >> /etc/shells
		echo "added $link to /etc/shells"
	fi
fi
