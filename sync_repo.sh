#!/usr/bin/env sh

set -o errexit
set -o nounset
set -o pipefail

main() {
  if ! sync_repo charts "$S3_BUCKET" "$S3_BUCKET_URL"; then
    log_error "Not all charts could be packaged and synced!"
  fi
}

sync_repo() {
  local repo_dir="${1?Specify repo dir}"
  local bucket="${2?Specify repo bucket}"
  local repo_url="${3?Specify repo url}"
  local sync_dir="${repo_dir}-sync"
  local index_dir="${repo_dir}-index"

  echo "Syncing repo '$repo_dir'..."

  mkdir -p "$sync_dir"
  if ! aws s3 cp "$bucket/index.yaml" "$index_dir/index.yaml"; then
    log_error "Exiting because unable to copy index locally. Not safe to proceed."
    exit 1
  fi

  local exit_code=0

  for dir in "$repo_dir"/*; do
    if helm dependency build "$dir"; then
      helm package --destination "$sync_dir" "$dir"
    else
      log_error "Problem building dependencies. Skipping packaging of '$dir'."
      exit_code=1
    fi
  done

  # Removing existing charts
  for f in $(aws s3 ls $bucket | awk '{print $4}' - | grep tgz); do
    rm -rf $sync_dir/$f
  done

  if helm repo index --url "$repo_url" --merge "$index_dir/index.yaml" "$sync_dir"; then
    # Move updated index.yaml to sync folder so we don't push the old one again
    mv -f "$sync_dir/index.yaml" "$index_dir/index.yaml"

    # Since existing charts are removed we can use `cp`
    aws s3 cp --recursive $sync_dir/ $bucket

    # Make sure index.yaml is synced last
    aws s3 cp "$index_dir/index.yaml" "$bucket"
  else
    log_error "Exiting because unable to update index. Not safe to push update."
    exit 1
  fi

  ls -l "$sync_dir"

  return "$exit_code"
}
log_error() {
    printf '\e[31mERROR: %s\n\e[39m' "$1" >&2
}

main