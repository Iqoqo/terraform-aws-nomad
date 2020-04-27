#!/bin/bash
# This script can be used to install Nomad and its dependencies. This script has been tested with the following
# operating systems:
#
# 1. Ubuntu 16.04
# 1. Amazon Linux

set -e

readonly DEFAULT_INSTALL_PATH="/opt/nomad"
readonly DEFAULT_NOMAD_USER="nomad"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SYSTEM_BIN_DIR="/usr/local/bin"

readonly SUPERVISOR_DIR="/etc/supervisor"
readonly SUPERVISOR_CONF_DIR="$SUPERVISOR_DIR/conf.d"

readonly SCRIPT_NAME="$(basename "$0")"

function print_usage {
  echo
  echo "Usage: install-nomad [OPTIONS]"
  echo
  echo "This script can be used to install Nomad and its dependencies. This script has been tested with Ubuntu 16.04 and Amazon Linux."
  echo
  echo "Options:"
  echo
  echo -e "  --environment\t\tThe environment to download the binary from. Required."
  echo -e "  --version\t\tThe version of Nomad to install. Required."
  echo -e "  --path\t\tThe path where Nomad should be installed. Optional. Default: $DEFAULT_INSTALL_PATH."
  echo -e "  --user\t\tThe user who will own the Nomad install directories. Optional. Default: $DEFAULT_NOMAD_USER."
  echo
  echo "Example:"
  echo
  echo "  install-nomad --environment staging --version 0.5.4"
}

function log {
  local readonly level="$1"
  local readonly message="$2"
  local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local readonly message="$1"
  log "INFO" "$message"
}

function log_warn {
  local readonly message="$1"
  log "WARN" "$message"
}

function log_error {
  local readonly message="$1"
  log "ERROR" "$message"
}

function assert_not_empty {
  local readonly arg_name="$1"
  local readonly arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

# Install steps are based on: http://unix.stackexchange.com/a/291098/215969
function install_supervisord_debian {
  sudo apt-get install -y supervisor
  sudo update-rc.d supervisor defaults

  create_supervisor_config
  sudo systemctl enable supervisor
}

# Install steps are based on: http://stackoverflow.com/a/31576473/483528
function install_supervisord_amazon_linux {
  sudo pip install supervisor

  # On Amazon Linux, /usr/local/bin is not in PATH for the root user, so we add symlinks to /usr/bin, which is in PATH
  if [[ ! -f "/usr/bin/supervisorctl" ]]; then
    sudo ln -s /usr/local/bin/supervisorctl /usr/bin/supervisorctl
  fi
  if [[ ! -f "/usr/bin/supervisord" ]]; then
    sudo ln -s /usr/local/bin/supervisord /usr/bin/supervisord
  fi

  sudo cp "$SCRIPT_DIR/supervisor-initd-script.sh" "/etc/init.d/supervisor"
  sudo chmod a+x /etc/init.d/supervisor
  sudo mkdir -p /var/log/supervisor

  create_supervisor_config
  sudo chkconfig --add supervisor
  sudo chkconfig supervisor on
}

function create_supervisor_config {
  sudo mkdir -p "$SUPERVISOR_CONF_DIR"
  sudo cp "$SCRIPT_DIR/supervisord.conf" "$SUPERVISOR_DIR/supervisord.conf"
}

function has_yum {
  [ -n "$(command -v yum)" ]
}

function has_apt_get {
  [ -n "$(command -v apt-get)" ]
}

function install_dependencies {
  log_info "Installing dependencies"

  if $(has_apt_get); then
    sudo apt-get update -y
    sudo apt-get install -y awscli curl unzip jq
    install_supervisord_debian
  elif $(has_yum); then
    sudo yum update -y
    sudo yum install -y aws curl unzip jq
    install_supervisord_amazon_linux
  else
    log_error "Could not find apt-get or yum. Cannot install dependencies on this OS."
    exit 1
  fi
}

function user_exists {
  local readonly username="$1"
  id "$username" >/dev/null 2>&1
}

function create_nomad_user {
  local readonly username="$1"

  if $(user_exists "$username"); then
    echo "User $username already exists. Will not create again."
  else
    log_info "Creating user named $username"
    sudo useradd "$username"
  fi
}

function create_nomad_install_paths {
  local readonly path="$1"
  local readonly username="$2"

  log_info "Creating install dirs for Nomad at $path"
  sudo mkdir -p "$path"
  sudo mkdir -p "$path/bin"
  sudo mkdir -p "$path/config"
  sudo mkdir -p "$path/data"
  sudo mkdir -p "$path/log"

  log_info "Changing ownership of $path to $username"
  sudo chown -R "$username:$username" "$path"
}

function install_binaries {
  local readonly environment="$1"
  local readonly version="$2"
  local readonly path="$3"
  local readonly username="$4"
  local url="https://s3-us-west-2.amazonaws.com/disco.nomad.$environment/latest/nomad_latest_linux_amd64"
  if [[ "${var.environment}" == "production" ]]; then
    url="https://s3-us-west-2.amazonaws.com/disco.nomad/latest/nomad_latest_linux_amd64"
  fi
  local readonly download_path="/tmp/nomad"
  local readonly bin_dir="$path/bin"
  local readonly nomad_dest_path="$bin_dir/nomad"
  local readonly run_nomad_dest_path="$bin_dir/run-nomad"

  log_info "Downloading Nomad $version from $url to $download_path"
  curl -o "$download_path" "$url"

  log_info "Moving Nomad binary to $nomad_dest_path"
  sudo mv "/tmp/nomad" "$nomad_dest_path"
  sudo chown "$username:$username" "$nomad_dest_path"
  sudo chmod a+x "$nomad_dest_path"

  local readonly symlink_path="$SYSTEM_BIN_DIR/nomad"
  if [[ -f "$symlink_path" ]]; then
    log_info "Symlink $symlink_path already exists. Will not add again."
  else
    log_info "Adding symlink to $nomad_dest_path in $symlink_path"
    sudo ln -s "$nomad_dest_path" "$symlink_path"
  fi

  log_info "Copying Nomad run script to $run_nomad_dest_path"
  sudo cp "$SCRIPT_DIR/../run-nomad/run-nomad" "$run_nomad_dest_path"
  sudo chown "$username:$username" "$run_nomad_dest_path"
  sudo chmod a+x "$run_nomad_dest_path"
}

function install {
  local environment=""
  local version=""
  local path="$DEFAULT_INSTALL_PATH"
  local user="$DEFAULT_NOMAD_USER"

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      --environment)
        environment="$2"
        shift
        ;;
      --version)
        version="$2"
        shift
        ;;
      --path)
        path="$2"
        shift
        ;;
      --user)
        user="$2"
        shift
        ;;
      --help)
        print_usage
        exit
        ;;
      *)
        log_error "Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  assert_not_empty "--environment" "$environment"
  assert_not_empty "--version" "$version"
  assert_not_empty "--path" "$path"
  assert_not_empty "--user" "$user"

  log_info "Starting Nomad install"

  install_dependencies
  create_nomad_user "$user"
  create_nomad_install_paths "$path" "$user"
  install_binaries "$environment" "$version" "$path" "$user"

  log_info "Nomad install complete!"
}

install "$@"