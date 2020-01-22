#! /bin/sh
#
# usage: instlibs.sh <path-to-dist-directory> <install-path> inst-options...
#
# installation helper script for qemu-irix:
# installs any packages containing shared libraries from the given inst source
# requires inst.rb in current directory
#
# examples:
# IRIX 5.3 or 6.5 32bit install from IRIX installation disk mounted at /mnt/irix
#	instlibs.sh /mnt/irix/dist irix -mCPUARCH=R4000 -mCPUBOARD=IP22 -mMODE=32bit
# IRIX 6.5 64bit install from IRIX installation disk mounted at /mnt/irix
#	instlibs.sh /mnt/irix/dist irix -mCPUARCH=R10000 -mCPUBOARD=IP32 -mMODE=64bit
# if you want to install an IRIX 6.5 overlay set, install IRIX6.5 foundation
# first, then install the overlay stuff to the same directory.

D=$1; shift
R=$1; shift

# find all subsystems containing shared library stuff
grep -e '\.so\>' -e '\<rld' $(find "$D" -name '*.idb') |
	sed 's/\(.*\):.* \<\([a-zA-Z0-9_.+\-]*\.[+a-zA-Z0-9_.+\-]*\).*/\1:\2/' |
	sort | uniq | (
		# loop over idb/subsystem list
		co=""; cs=""; cn=""
		while read l; do
			# extract filename and subsystem
			n=$(echo $l|sed 's/:.*//;s/\.idb//')
			s=$(echo $l|sed 's/[^:]*://')
			if [ "$cn" != "$n" -a -n "$cs" ]; then
				# idb file changed, install stuff from old idb
				echo "*** from $cn install $co:"
                $(dirname $0)/inst.rb i "$cn" $cs -r"$R" $*
				co=""; cs="";
			fi
			co="$co $s"; cs="$cs -s$s"
			cn=$n
		done
		# install leftover packages from last idb
		if [ -n "$cs" ]; then
			echo "*** from $cn install $co:"
			$(dirname $0)/inst.rb i "$cn" $cs -r"$R" $*
		fi
	)
