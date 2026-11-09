#!/usr/bin/env bash
# run_requirement.sh — install everything in requirement.txt on a RunPod pod (or any Ubuntu 24.04 machine).
#
# Run it every time you start a new pod: RunPod wipes the container disk on restart,
# but /workspace survives. Packages that are already installed are skipped, so a re-run is quick.
#
# Usage:
#   bash run_requirement.sh            # full install + browser desktop for rviz2 / Gazebo
#   bash run_requirement.sh --headless # no GUI, enough for the IK sweep
#
# Env overrides:
#   WS_DIR=/workspace/ros2_ws   colcon workspace (keep it on /workspace so it survives restarts)
#   VNC_PASSWORD=armteam        password for the browser desktop

set -euo pipefail

HEADLESS=0
for arg in "$@"; do
  case "$arg" in
    --headless) HEADLESS=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_FILE="${SCRIPT_DIR}/requirement.txt"
WS_DIR="${WS_DIR:-/workspace/ros2_ws}"
VNC_PASSWORD="${VNC_PASSWORD:-armteam}"
ROS_DISTRO=jazzy

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# RunPod containers run as root without sudo; regular machines need sudo.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive

[ -f "$REQ_FILE" ] || { echo "requirement.txt not found next to this script." >&2; exit 1; }

# Print the packages listed under [section] in requirement.txt.
packages_in() {
  awk -v want="[$1]" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^\[.*\]$/ { in_sec = ($0 == want); next }
    in_sec { print $1 }
  ' "$REQ_FILE"
}

# Install the packages of the given sections that are not installed yet.
install_sections() {
  local missing=() pkg
  for section in "$@"; do
    while read -r pkg; do
      dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done < <(packages_in "$section")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "Already installed: $*"
    return
  fi
  echo "Installing ${#missing[@]} package(s): ${missing[*]}"
  $SUDO apt-get install -y --no-install-recommends "${missing[@]}"
}

# --- 0. OS check -------------------------------------------------------------
. /etc/os-release
if [ "${VERSION_ID:-}" != "24.04" ]; then
  echo "This needs Ubuntu 24.04 (found ${PRETTY_NAME:-unknown})." >&2
  echo "ROS 2 Jazzy / MoveIt 2 binaries are only published for 24.04." >&2
  echo "On RunPod, pick a template whose base image is Ubuntu 24.04." >&2
  exit 1
fi

# --- 1. Base packages and locale ---------------------------------------------
log "Base packages"
$SUDO apt-get update
install_sections base
$SUDO locale-gen en_US en_US.UTF-8 >/dev/null
$SUDO update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# --- 2. ROS 2 apt repository -------------------------------------------------
if ! dpkg -s ros2-apt-source >/dev/null 2>&1; then
  log "Adding the ROS 2 apt repository"
  $SUDO add-apt-repository -y universe
  ROS_APT_SOURCE_VERSION=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
    | grep -F '"tag_name"' | awk -F'"' '{print $4}')
  curl -fsSL -o /tmp/ros2-apt-source.deb \
    "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${VERSION_CODENAME}_all.deb"
  $SUDO dpkg -i /tmp/ros2-apt-source.deb
  rm -f /tmp/ros2-apt-source.deb
  $SUDO apt-get update
fi

# --- 3. ROS 2, MoveIt 2, Gazebo, Python libraries ----------------------------
log "ROS 2 ${ROS_DISTRO}, MoveIt 2, Gazebo, CycloneDDS (first run takes a while)"
if [ "$HEADLESS" -eq 1 ]; then
  install_sections ros python
else
  install_sections ros desktop python
fi

# --- 4. rosdep ---------------------------------------------------------------
log "rosdep"
[ -f /etc/ros/rosdep/sources.list.d/20-default.list ] || $SUDO rosdep init
rosdep update --rosdistro "$ROS_DISTRO" >/dev/null

# --- 5. Shell environment (CycloneDDS for the whole team) --------------------
log "Configuring ~/.bashrc"
add_line() { grep -qxF "$1" ~/.bashrc 2>/dev/null || echo "$1" >> ~/.bashrc; }
add_line "source /opt/ros/${ROS_DISTRO}/setup.bash"
add_line "export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
add_line "export LANG=en_US.UTF-8"
add_line "[ -f ${WS_DIR}/install/setup.bash ] && source ${WS_DIR}/install/setup.bash"

# --- 6. Workspace (on /workspace, so it survives pod restarts) ---------------
log "Workspace at ${WS_DIR}"
mkdir -p "${WS_DIR}/src"
if [ ! -e "${WS_DIR}/src/armteam" ]; then
  git clone https://github.com/DDongs068/armteam "${WS_DIR}/src/armteam" || \
    echo "Could not clone armteam; clone it into ${WS_DIR}/src yourself."
fi

# --- 7. Browser desktop for rviz2 / Gazebo GUI (skipped with --headless) -----
if [ "$HEADLESS" -eq 0 ]; then
  log "Browser desktop (XFCE + TigerVNC + noVNC)"
  install_sections gui

  mkdir -p ~/.vnc
  echo "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd
  chmod 600 ~/.vnc/passwd
  cat > ~/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
  chmod +x ~/.vnc/xstartup

  cat > ~/start_gui.sh <<'EOF'
#!/usr/bin/env bash
# Starts the desktop on :1 and serves it in the browser on port 6080.
vncserver -kill :1 >/dev/null 2>&1 || true
vncserver :1 -geometry 1920x1080 -depth 24 -localhost yes
pkill -f "websockify.*6080" >/dev/null 2>&1 || true
nohup websockify --web /usr/share/novnc 6080 localhost:5901 >/tmp/novnc.log 2>&1 &
echo "Desktop ready: open HTTP port 6080 from the RunPod 'Connect' menu, then vnc.html"
EOF
  chmod +x ~/start_gui.sh
  add_line "export DISPLAY=:1"
fi

# --- 8. Check ----------------------------------------------------------------
log "Checking the install"
set +u
# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO}/setup.bash"
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
PKGS="$(ros2 pkg list)"
for p in moveit_ros_planning_interface ros_gz_sim rmw_cyclonedds_cpp; do
  if grep -qx "$p" <<<"$PKGS"; then echo "  OK       $p"; else echo "  MISSING  $p"; fi
done
echo "  RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION}"

cat <<EOF

Done.
  1. Open a new terminal (or run: source ~/.bashrc)
  2. Put the TA's INDEX01 URDF under ${WS_DIR}/src
  3. cd ${WS_DIR} && colcon build && source install/setup.bash
EOF
if [ "$HEADLESS" -eq 0 ]; then
  echo "  4. For rviz2 / Gazebo: run ~/start_gui.sh, then open HTTP port 6080 in RunPod"
fi
echo
echo "New pod? Just run this script again: installed packages are skipped."
