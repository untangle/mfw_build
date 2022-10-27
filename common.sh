get_openwrt_version() {
  git describe --tags --abbrev=0 --match 'v[0-9][0-9].[0-9][0-9]*' 2> /dev/null | sed -e 's/^v//' || git log -n 1 --pretty=%D  | perl -pe 's/.*, .+?\/(.+)/$1/' || get_version_without_git
}

get_mfw_version() {
 git describe --always --tags --long || get_version_without_git
}

get_mfw_short_version() {
  git describe --always --tags --abbrev=0 || get_version_without_git
}

get_version_without_git() {
  echo "not_from_git"
}
