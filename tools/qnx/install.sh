#!/bin/sh
# Copyright (c) Xia Zhongyang.
# Licensed under the MIT License.
#
# Installs PowerShell on QNX Neutrino 6.5.0 from an install tree made by
# tools/qnx/build.sh, which places this script at the top of the tree.
#
# Usage: install.sh [options]
#
#   --prefix DIR     where to install (default: /opt/powershell)
#   --bindir DIR     where the pwsh link goes (default: /usr/bin)
#   --login-shell    also list pwsh in /etc/shells, so it can be a login shell
#   --uninstall      remove what an earlier install made
#
# Running it again replaces an earlier install with this tree. It never
# replaces a pwsh or an install directory it did not make.

set -eu

prefix=/opt/powershell
bindir=/usr/bin
login_shell=0
uninstall=0
marker=.installed-by-install.sh

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
}

if [ $uninstall = 1 ]; then
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
	if [ ! -f /etc/shells ] || ! grep -qx "$link" /etc/shells; then
		echo "$link" >> /etc/shells
		echo "added $link to /etc/shells"
	fi
fi
