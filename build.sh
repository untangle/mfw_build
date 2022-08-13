#! /bin/bash -x

set -e
set -o pipefail

# hides perl warning about locale
export LC_ALL=${LC_ALL:-C}

# make sure the time conversion from epoch format to human-readable
# one uses HQ timezone
export TZ="America/Los_Angeles"

usage() {
  echo "Usage: $0 [-d <device>] [-l <libc>] [-v (latest|<branch>|<tag>)] [-c (false|true)] [-r <region>]"
  echo "  -d <device>               : x86_64, omnia, wrt3200, wrt1900, wrt32x, espressobin, rpi3 (defaults to x86_64)"
  echo "  -l <libc>                 : musl, glibc (defaults to musl)"
  echo "  -m <make options>         : pass those to OpenWRT's make \"as is\" (default is -j32)"
  echo "  -u                        : 'upstream' build, with no MFW feeds"
  echo "  -c true|false             : start clean or not (default is false, meaning \"do not start clean\""
  echo "  -r <region>               : us, eu (defaults to us)"
  echo "  -v release|<branch>|<tag> : version to build from (defaults to master)"
  echo "                              - 'release' is a special keyword meaning 'most recent tag from each"
  echo "                                package's source repository'"
  echo "                              - <branch> or <tag> can be any valid git object as long as it exists"
  echo "                                in each package's source repository (mfw_admin, packetd, etc)"
}

# cleanup
VERSION_DATE_FILE="version.date"
VERSION_FILE="version"
cleanup() {
  git checkout -- ${VERSION_FILE} ${VERSION_DATE_FILE} 2> /dev/null || true
}

apt update -q
apt install -y libbpf-dev libelf-dev meson python3-pip
pip3 install pyelftools

# CLI options
START_CLEAN="false"
REGION="us"
DEVICE="x86_64"
LIBC="musl"
VERSION="master"
MAKE_OPTIONS="-j32"
NO_MFW_FEEDS=""
while getopts "uhc:r:d:l:v:m:" opt ; do
  case "$opt" in
    c) START_CLEAN="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    d) DEVICE="$OPTARG" ;;
    l) LIBC="$OPTARG" ;;
    v) VERSION="$OPTARG" ;;
    m) MAKE_OPTIONS="$OPTARG" ;;
    u) NO_MFW_FEEDS=1 ;;
    h) usage ; exit 0 ;;
  esac
done

# main
trap cleanup ERR INT
CURDIR=$(dirname $(readlink -f $0))
source ${CURDIR}/common.sh

# grab github.com's ssh key, and check ssh-agent;
# this is needed for private repositories (see MFW-877)
mkdir -p ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts
ssh-add -l

# set MFW_VERSION, or not; this looks convoluted, but ?= in Makefiles
# doesn't work if the variable is defined but empty
if [[ $VERSION == "release" ]] ; then
  VERSION_ASSIGN=""
else
  VERSION_ASSIGN="MFW_VERSION=${VERSION}"
  export MFW_VERSION="${VERSION}"
fi

rm -fr bin/targets

# always clean grub2, as it doesn't build twice in a row
rm -fr build_dir/target*/*/grub-pc

# start clean only if explicitely requested
case $START_CLEAN in
  false|0) : ;;
  *) [ -f .config ] || make defconfig
     make $MAKE_OPTIONS $VERSION_ASSIGN clean
     rm -fr build_dir staging_dir 
		 ./scripts/feeds clean
		 ;;
esac

# set timestamp for files
SOURCE_DATE_EPOCH=$(date +"%s")
echo $SOURCE_DATE_EPOCH >| ${VERSION_DATE_FILE}
# also save it, as a readable format, in a file that won't be cleaned
# up once the build is finished, so post-build process like artifact
# archiving, etc can still access it
SOURCE_DATE=$(date -d @$SOURCE_DATE_EPOCH +%Y%m%dT%H%M)
mkdir -p tmp
echo $SOURCE_DATE >| tmp/${VERSION_DATE_FILE}

if [ -z "$NO_MFW_FEEDS" ]; then
  # add MFW feed definitions
  cp ${CURDIR}/feeds.conf.mfw feeds.conf

  # point to correct branch for packages
  packages_feed=$(grep -P '^src-git packages' feeds.conf.default)
  perl -i -pe "s#^src-git packages .+#${packages_feed}#" feeds.conf

  # setup feeds
  ./scripts/feeds update -a
  ./scripts/feeds install -a -f

  # create config file for MFW
  ./feeds/mfw/configs/generate.sh -d $DEVICE -l $LIBC -r $REGION >| .config

fi

# config
make defconfig

## versioning
# static
# FIXME: move those to feeds' config once stable and agreed upon
cat >> .config <<EOF
CONFIG_VERSION_DIST="MFW"
CONFIG_VERSION_MANUFACTURER="Untangle"
CONFIG_VERSION_BUG_URL="https://jira.untangle.com/projects/MFW/"
CONFIG_VERSION_HOME_URL="https://github.com/untangle/mfw_feeds"
CONFIG_VERSION_SUPPORT_URL="https://support.untangle.com/hc/en-us/articles/360008238393"
CONFIG_VERSION_PRODUCT="MFW"
EOF

# update for DPDK - this should be done as part of the package
cat >> .config <<EOF
CONFIG_EXPERT=y
CONFIG_HUGETLB_PAGE=y
CONFIG_HUGETLBFS=y
CONFIG_KERNEL_DEBUG_KERNEL=y
CONFIG_KERNEL_PROC_PAGE_MONITOR=y
CONFIG_KERNEL_DEV_PAGEMAP_OPS=y
CONFIG_KERNEL_HUGETLB_PAGE=y
CONFIG_KERNEL_MEMORY_FAILURE=y
CONFIG_KERNEL_PROC_FS=y
CONFIG_PAGE_MONITOR=y
CONFIG_MMU=y
CONFIG_NUMA=y
CONFIG_UIO=y
CONFIG_VFIO_IOMMU_TYPE1=y
CONFIG_VFIO_VIRQFD=y
CONFIG_VFIO=y
CONFIG_VFIO_NOIOMMU=y
CONFIG_VFIO_PCI=y
CONFIG_VFIO_PCI_MMAP=y
CONFIG_PACKAGE_libnuma=y
CONFIG_PACKAGE_numactl=y
EOF

# dynamic
openwrtVersion="$(get_openwrt_version)"
mfwVersion="$(get_mfw_version)"
mfwShortVersion="$(get_mfw_short_version)"
echo CONFIG_VERSION_CODE="$openwrtVersion" >> .config
echo CONFIG_VERSION_NUMBER="$mfwVersion" >> .config
echo $mfwVersion >| $VERSION_FILE
if [ -n "$BUILD_URL" ] ; then # Jenkins build
  # adjust device name to match exact OpenWrt specification
  case $DEVICE in
    wrt1900) DEVICE=wrt1900acs ;;
    wrt3200) DEVICE=wrt3200acm ;;
    x86_64) DEVICE=x86-64 ;;
  esac
  packagesList="mfw-${DEVICE}-Packages_${mfwVersion}_${SOURCE_DATE}.txt"
  echo CONFIG_VERSION_MANUFACTURER_URL="https://downloads.untangle.com/public/mfw/${mfwShortVersion}/manifest/${packagesList}" >> .config
else
  echo CONFIG_VERSION_MANUFACTURER_URL="developer build" >> .config
fi

# download
make $MAKE_OPTIONS $VERSION_ASSIGN download

# if the 1st build fails, try again with the same options (typically
# -j32) before going with the super-inefficient -j1
if ! make $MAKE_OPTIONS $VERSION_ASSIGN ; then
  if ! make $MAKE_OPTIONS $VERSION_ASSIGN ; then
    make -j1 V=s $VERSION_ASSIGN
  fi
fi

cleanup
