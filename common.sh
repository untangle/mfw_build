get_openwrt_version() {
  git describe --tags --abbrev=0 --match 'v[0-9][0-9].[0-9][0-9]*' 2> /dev/null | sed -e 's/^v//' || git log --decorate --pretty=oneline -n 10 | perl -lne 'if (m/^[a-f0-9]+ \(.+?\/(.+)\)/) {print $1 ; exit}'
}

get_mfw_version() {
 git describe --always --tags --long
}

get_mfw_short_version() {
  git describe --always --tags --abbrev=0
}
