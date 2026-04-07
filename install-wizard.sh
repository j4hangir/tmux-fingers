#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLATFORM=$(uname -s)
VERSION=$(grep '^version:' "$CURRENT_DIR/shard.yml" | awk '{print $2}')
action=$1

# set up exit trap
function finish {
  exit_code=$?

  # only intercept exit code when there is an action defined (download, or
  # build from source), otherwise we'll enter an infinte loop of sourcing
  # tmux.conf
  if [[ -z "$action" ]]; then
    exit $exit_code
  fi

  if [[ $exit_code -eq 0 ]]; then
    echo "Reloading tmux.conf"
    tmux source ~/.tmux.conf
    exit 0
  else
    echo "Something went wrong. Please any key to close this window"
    read -n 1
    exit 1
  fi
}

trap finish EXIT

function install_from_source() {
  echo "Installing tmux-fingers v$VERSION from source..."

  # check if shards is installed
  if ! command -v shards >/dev/null 2>&1; then
    echo "crystal is not installed. Please install it first."
    echo ""
    echo "  https://crystal-lang.org/install/"
    echo ""
    exit 1
  fi

  pushd $CURRENT_DIR > /dev/null
    WIZARD_INSTALLATION_METHOD=build-from-source shards build --production
  popd > /dev/null

  echo "Build complete!"
  exit 0
}

function install_with_brew() {
  echo "Installing tmux-fingers v$VERSION with brew..."
  brew tap morantron/tmux-fingers
  brew install tmux-fingers

  echo "Installation complete!"
  exit 0
}


function download_binary() {
  mkdir -p $CURRENT_DIR/bin

  if [[ ! "$(uname -m)" == "x86_64" ]]; then
    echo "tmux-fingers binaries are only provided for x86_64 architecture."
    exit 1
  fi

  local project_api="https://git.j4hangir.com/api/v4/projects/tmux%2Ftmux-fingers"
  local project_url="https://git.j4hangir.com/tmux/tmux-fingers"

  echo "Getting latest tag..."

  tags=$(curl -sSf "$project_api/repository/tags" 2>&1)

  if [[ $? -ne 0 || -z "$tags" || "$tags" == "[]" ]]; then
    echo "Could not fetch tags from $project_api/repository/tags"
    echo "Response: $tags"
    exit 1
  fi

  tag=$(echo "$tags" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"\([^"]*\)"/\1/')

  if [[ -z "$tag" ]]; then
    echo "Could not extract tag name from tags response."
    echo "Response: $tags"
    exit 1
  fi

  url="$project_url/-/jobs/artifacts/$tag/raw/tmux-fingers?job=build"
  echo "Installing tmux-fingers v$VERSION (binary: $tag)..."

  # download binary to bin/tmux-fingers; --fail so we surface HTTP errors
  if ! curl -sSfL "$url" -o "$CURRENT_DIR/bin/tmux-fingers"; then
    echo "Failed to download binary. The CI build for $tag may still be running or may have failed."
    echo "Check $project_url/-/pipelines"
    exit 1
  fi
  chmod a+x $CURRENT_DIR/bin/tmux-fingers

  echo "Download complete!"
  exit 0
}

if [[ "$1" == "download-binary" ]]; then
  download_binary
fi

if [[ "$1" == "install-with-brew" ]]; then
  echo "Installing with brew..."
  install_with_brew
  exit 1
fi

if [[ "$1" == "install-from-source" ]]; then
  install_from_source
fi

function binary_or_brew_label() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    echo "Install with brew"
  else
    echo "Download binary"
  fi
}

function binary_or_brew_action() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    echo "install-with-brew"
  else
    echo "download-binary"
  fi
}

function get_message() {
  if [[ "$FINGERS_UPDATE" == "1" ]]; then
    echo "It looks like tmux-fingers has been updated. We need to rebuild the binary."
  else
   echo "It looks like it is the first time you are running the plugin. We first need to get tmux-fingers binary for things to work."
  fi

}

tmux display-menu -T "tmux-fingers v$VERSION" \
  "" \
  "- " "" ""\
  "-  #[nodim,bold]Welcome to tmux-fingers! ✌️ " "" ""\
  "- " "" ""\
  "-  $(get_message) " "" "" \
  "- " "" ""\
  "" \
  "$(binary_or_brew_label)" b "new-window \"$CURRENT_DIR/install-wizard.sh $(binary_or_brew_action)\"" \
  "Build from source (crystal required)" s "new-window \"$CURRENT_DIR/install-wizard.sh install-from-source\"" \
  "" \
  "Exit" q ""
