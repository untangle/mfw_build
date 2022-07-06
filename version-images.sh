#! /bin/bash

set -e
set -o pipefail

# hides perl warning about locale
export LC_ALL=${LC_ALL:-C}

# CLI options
usage() {
  echo "$0 -d <device> -o <outputDir> [-c] [-n] [-r <region>] [-t <timestamp>]"
  echo "  -c             : start by cleaning output directory"
  echo "  -d <device>    : which device"
  echo "  -n             : do not upload manifests to s3"
  echo "  -r <region>               : us, eu (defaults to us)"
  echo "  -o <outputDir> : where to store the renamed images "
  echo "  -t <timestamp> : optional; defaults to $(date +"%Y%m%dT%H%M")"
}

DEVICE=""
REGION="us"
OUTPUT_DIR=""
START_CLEAN=""
UPLOAD_TO_S3="yes"
TS=$(date +"%Y%m%dT%H%M")
while getopts "hcnd:o:r:t:" opt ; do
  case "$opt" in
    c) START_CLEAN=1 ;;
    d) DEVICE="$OPTARG" ;;
    n) UPLOAD_TO_S3="" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    t) TS="$OPTARG" ;;
    h) usage ; exit 0 ;;
  esac
done

if [ -z "$OUTPUT_DIR" ] || [ -z "$DEVICE" ] ; then
  usage
  exit 1
fi

# main
CURDIR=$(dirname $(readlink -f $0))
source ${CURDIR}/common.sh

SHORT_VERSION="$(get_openwrt_version)"
FULL_VERSION="$(get_mfw_version)_${TS}"

case $DEVICE in
  wrt1900) DEVICE=wrt1900acs ;;
  wrt3200) DEVICE=wrt3200acm ;;
  x86_64) DEVICE=x86-64 ;;
  rpi3) DEVICE=rpi-3 ;;
esac

PACKAGES_FILE="mfw_${REGION}_${DEVICE}-Packages_${FULL_VERSION}.txt"

[[ -z "$START_CLEAN" ]] || rm -fr $OUTPUT_DIR
mkdir -p $OUTPUT_DIR

find bin/targets -iregex '.+\(gz\|img\|vdi\|vmdk\|bin\|kmod-mac80211-hwsi.+ipk\)' | grep -v Packages.gz | while read f ; do
  b=$(basename "$f")
  # add our full version
  newName=${b/./_${FULL_VERSION}.}
  # remove extraneous informatio
  newName=$(echo $newName | perl -pe 's/-(brcm2708-bcm2710|squashfs|mvebu-cortexa\d+|linksys|turris|globalscale|cznic|sdcard|v7-emmc)//g')
  # rename *.bin (confusing to customers) to *.img
  newName=${newName/.bin/.img}
  # add region name
  newName=${newName/mfw_/mfw-}
  newName=${newName/mfw-/mfw-${REGION}-}
  cp $f ${OUTPUT_DIR}/$newName
done

find ${OUTPUT_DIR} -iname "*esxi_v*.vmdk" | while read f ; do
  flat_b=$(basename "$f" | sed "s|esxi_v|esxi-flat_v|g")
  sed -i "s|FLAT \".*\"|FLAT \"$flat_b\"|g" $f
done

# add a list of MFW packages, with their versions
cp bin/packages/*/mfw/Packages ${OUTPUT_DIR}/${PACKAGES_FILE}

# also push that list to s3 (Jenkins should have the necessary AWS_*
# environment variables)
if [[ -n "$UPLOAD_TO_S3" ]] ; then
  s3path="s3://downloads.untangle.com-temp/mfw/${SHORT_VERSION}/manifest/${PACKAGES_FILE}"
  rc=1
  for i in $(seq 1 5) ; do
    if s3cmd put bin/packages/*/mfw/Packages $s3path ; then
      rc=0
      break
    fi
  done
fi

exit $rc
