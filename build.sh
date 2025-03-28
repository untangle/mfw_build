#! /bin/bash -x

set -e
set -o pipefail

# hides perl warning about locale
export LC_ALL=${LC_ALL:-C}

# make sure the time conversion from epoch format to human-readable
# one uses HQ timezone
export TZ="America/Los_Angeles"


usage() {
  echo "Usage: $0 [-d <device>] [-l <libc>] [-v (release|<branch>|<tag>)] [-c (false|true)] [-r <region>] [-u] [-e] [-t <target>] [-f <local_path>]"
  echo "  -d <device>               : x86_64, omnia, wrt3200, wrt1900, wrt32x, espressobin, rpi3 (defaults to x86_64)"
  echo "  -l <libc>                 : musl, glibc (defaults to musl)"
  echo "  -m <make options>         : pass those to OpenWRT's make \"as is\" (default is -j32)"
  echo "  -t <target>               : target to pass to OpenWRT's make (default is 'world'; can be 'toolchain/install')"
  echo "  -n                        : do not include any packages from the MFW feeds"
  echo "  -u                        : 'upstream' build targetting x86-64/musl, without any use of MFW feeds"
  echo "  -c true|false             : start clean or not (default is false, meaning \"do not start clean\""
  echo "  -r <region>               : us, eu (defaults to us)"
  echo "  -f <local_path>           : use package sources in <local_path>/<forge>/<repo> instead of fetching from github (defaults to using github)"
  echo "  -e                        : exit on first build failure instead of retrying (default is to try 3 times)"
  echo "  -v release|<branch>|<tag> : version to build from (defaults to master)"
  echo "                              - 'release' is a special keyword meaning 'most recent tag from each"
  echo "                                package's source repository'"
  echo "                              - <branch> or <tag> can be any valid git object as long as it exists"
  echo "                                in each package's source repository (mfw_admin, packetd, etc)"
}
TEMP=$(getopt -o d:l:m:nuehc:r:v:t:f: \
       --long \
       device:,libc:,make-opts:,no-mfw-packages,upstream,clean,region,version:,with-dpdk,exit-on-first-failure,make-target -- "$@")
if [ $? != 0 ]
then
    usage
    exit 1
fi

eval set -- "$TEMP"

# cleanup
VERSION_DATE_FILE="version.date"
VERSION_FILE="version"
cleanup() {
  git checkout -- ${VERSION_FILE} ${VERSION_DATE_FILE} 2> /dev/null || true
}

# CLI options
START_CLEAN="false"
REGION="us"
DEVICE="x86_64"
LIBC="musl"
VERSION="master"
WITH_DPDK=
MAKE_OPTIONS="-j32"
MAKE_TARGET="world"
NO_MFW_FEEDS=""
NO_MFW_PACKAGES=""
LOCAL_SOURCE_PATH=""
EXIT_ON_FIRST_FAILURE=""
while true ; do
  case "$1" in
    -c | --clean ) START_CLEAN="$2"; shift 2;;
    -r | --region ) REGION="$2"; shift 2;;
    -f | --local-source ) export LOCAL_SOURCE_PATH="$2"; shift 2 ;;
    -e | --exit-on-first-failure) EXIT_ON_FIRST_FAILURE=1; shift ;;
    -d | --device ) DEVICE="$2"; shift 2 ;;
    -l | --libc ) LIBC="$2"; shift 2 ;;
    -v | --version ) VERSION="$2"; shift 2 ;;
    -m | --make-opts ) MAKE_OPTIONS="$2"; shift 2 ;;
    -t | --make-target ) MAKE_TARGET="$2"; shift 2;;
    -u | --upstream) NO_MFW_FEEDS=1; shift ;;
    -n | --no-mfw-packages) NO_MFW_PACKAGES="-u"; shift ;; # easily passable to configs/generate.sh
    --with-dpdk ) WITH_DPDK=--with-dpdk; shift ;;
    -h) usage ; exit 0 ;;
    -- ) shift; break ;;
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
ssh-add -l || {
    echo "build.sh: could not connect to ssh agent; crossing fingers and continuing..." 1>&2;
}

# Prevent the dubious ownership message from breaking the version 
# this probably isn't safe to run directly outside of a docker container
git config --global --list | grep -q "safe.directory=*" || git config --global --add safe.directory "*"

# set MFW_VERSION, or not; this looks convoluted, but ?= in Makefiles
# doesn't work if the variable is defined but empty
if [[ $VERSION == "release" ]] ; then
  VERSION_ASSIGN=""
else
  VERSION_ASSIGN="MFW_VERSION=${VERSION}"
  export MFW_VERSION="${VERSION}"
  if [[ -n "$LOCAL_SOURCE_PATH" ]] ; then
    VERSION_ASSIGN="$VERSION_ASSIGN LOCAL_SOURCE_PATH=${LOCAL_SOURCE_PATH}"
  fi
fi

# start clean only if explicitely requested
case $START_CLEAN in
  false|0) : ;;
  *) [ -f .config ] || make defconfig
     make $MAKE_OPTIONS $VERSION_ASSIGN clean
     rm -fr build_dir package/feeds staging_dir ;;
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

# add our feeds definitions
cp ${CURDIR}/feeds.conf.mfw feeds.conf

# point to correct branch for packages
packages_feed=$(grep -P '^src-git(-full)? packages' feeds.conf.default)
perl -i -pe "s#^src-git(-full)? packages .+#${packages_feed}#" feeds.conf

# setup feeds
if [ -n "$NO_MFW_FEEDS" ]; then # remove MFW feed entry
  perl -i -ne "print unless m/mfw/" feeds.conf
fi
./scripts/feeds update -a
./scripts/feeds install -a -f -p mfw
./scripts/feeds install -a packages

if [ -d ./feeds/mfw/configs ] ; then
  # create config file for MFW
  ./feeds/mfw/configs/generate.sh $NO_MFW_PACKAGES -d $DEVICE -l $LIBC -r $REGION $WITH_DPDK >| .config

  # apply overrides for MFW into other feeds
  ./feeds/mfw/configs/apply_overrides.sh
else
  cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
# CONFIG_USE_LIBSTDCXX is not set
# CONFIG_VDI_IMAGES is not set
# CONFIG_VMDK_IMAGES is not set
# CONFIG_ESXI_VMDK_IMAGES is not set
EOF
  if [ "$LIBC" = "musl" ] ; then
    cat >> .config <<EOF
CONFIG_TARGET_SUFFIX="musl"
CONFIG_LIBC="musl"
CONFIG_LIBC_USE_MUSL=y
CONFIG_USE_MUSL=y
EOF
  else
    cat >> .config <<EOF
CONFIG_TARGET_SUFFIX="gnu"
CONFIG_LIBC="glibc"
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_LIBC_USE_GLIBC=y
CONFIG_USE_GLIBC=y
# CONFIG_LIBC_USE_MUSL is not set
# CONFIG_USE_MUSL is not set
EOF
  fi
fi

# config
make defconfig

## versioning
# static
# FIXME: move those to feeds' config once stable and agreed upon
cat >> .config <<EOF
CONFIG_VERSION_DIST="MFW"
CONFIG_VERSION_MANUFACTURER="Untangle"
CONFIG_VERSION_BUG_URL="https://jira.edge.arista.com/projects/MFW/"
CONFIG_VERSION_HOME_URL="https://github.com/untangle/mfw_feeds"
CONFIG_VERSION_SUPPORT_URL="https://support.edge.arista.com/hc/en-us/articles/360008238393"
CONFIG_VERSION_PRODUCT="MFW"
EOF

# dynamic
openwrtVersion="$(get_openwrt_version)"
mfwVersion="$(get_mfw_version)"
mfwShortVersion="$(get_mfw_short_version)"
echo CONFIG_VERSION_CODE="$openwrtVersion" >> .config
echo CONFIG_VERSION_NUMBER="$mfwVersion" >> .config
echo CONFIG_VERSION_REPO="https://downloads.openwrt.org/releases/$openwrtVersion" >> .config
echo $mfwVersion >| $VERSION_FILE
if [ -n "$BUILD_URL" ] ; then # Jenkins build
  # adjust device name to match exact OpenWrt specification
  case $DEVICE in
    wrt1900) DEVICE=wrt1900acs ;;
    wrt3200) DEVICE=wrt3200acm ;;
    x86_64) DEVICE=x86-64 ;;
  esac
  packagesList="mfw-${DEVICE}-Packages_${mfwVersion}_${SOURCE_DATE}.txt"
  echo CONFIG_VERSION_MANUFACTURER_URL="https://downloads.edge.arista.com/public/mfw/${mfwShortVersion}/manifest/${packagesList}" >> .config
else
  echo CONFIG_VERSION_MANUFACTURER_URL="developer build" >> .config
fi

# download -- specifically using -j32 to speed up download.
make -j32 $VERSION_ASSIGN download

# if the 1st build fails, try again with the same options (typically
# -j32) before going with the super-inefficient -j1
rc=0
make $MAKE_OPTIONS $VERSION_ASSIGN $MAKE_TARGET || rc=$?
if [ $rc != 0 ] ; then
  if [ -n "$EXIT_ON_FIRST_FAILURE" ] ; then
    :
  else # retry
    if ! make $MAKE_OPTIONS $VERSION_ASSIGN $MAKE_TARGET; then
      make -j1 V=s $VERSION_ASSIGN $MAKE_TARGET
    fi
    rc=0
  fi
fi

cleanup

exit $rc
