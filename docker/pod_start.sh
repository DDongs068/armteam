#!/usr/bin/env bash
# pod_start.sh — runs every time a pod starts from the armteam image.
#   1. Creates the colcon workspace on the persistent /workspace volume (first start only)
#   2. Starts the browser desktop on port 6080 (set START_GUI=0 to skip)
#   3. Hands over to RunPod's /start.sh (SSH, Jupyter, web terminal)
#
# Pod env vars (set in the RunPod template):
#   WS_DIR        workspace path, default /workspace/ros2_ws
#   START_GUI     1 (default) or 0
#   VNC_PASSWORD  desktop password, default armteam

WS_DIR="${WS_DIR:-/workspace/ros2_ws}"

mkdir -p "${WS_DIR}/src"
if [ ! -e "${WS_DIR}/src/armteam" ]; then
  git clone https://github.com/DDongs068/armteam "${WS_DIR}/src/armteam" \
    || echo "[armteam] Could not clone the repo; clone it into ${WS_DIR}/src yourself."
fi

# The image's ~/.bashrc sources ROS and sets CycloneDDS; make sure the
# workspace overlay line points at this pod's WS_DIR too.
line="[ -f ${WS_DIR}/install/setup.bash ] && source ${WS_DIR}/install/setup.bash"
grep -qxF "$line" ~/.bashrc || echo "$line" >> ~/.bashrc

if [ -n "${VNC_PASSWORD:-}" ]; then
  echo "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd
fi

if [ "${START_GUI:-1}" = "1" ] && [ -x ~/start_gui.sh ]; then
  ~/start_gui.sh || echo "[armteam] Desktop did not start; run ~/start_gui.sh by hand."
fi

exec /start.sh
