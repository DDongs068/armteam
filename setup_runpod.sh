#!/usr/bin/env bash
# =============================================================================
# armteam Runpod 환경 설치 스크립트
#
# 동작 순서:
#   1) 사전 점검: root 권한, Ubuntu 24.04, 디스크 여유 공간, 저장소 위치
#   2) ROS 2 apt 저장소 등록
#   3) ROS 2 Jazzy, MoveIt 2, Gazebo Harmonic 및 headless 렌더링 도구 설치
#   4) 저장소에 ROS 패키지가 있으면 의존성 설치 후 colcon build
#   5) 셸 환경 등록 및 설치 결과 검증
#
# 사용법: bash /workspace/armteam/setup_runpod.sh
#
# 참고:
#   - 여러 번 실행해도 안전하다.
#   - apt 패키지는 컨테이너 디스크에 설치되므로, 새 Pod에서는 다시 실행해야 한다.
#     /workspace(볼륨)에 있는 코드와 빌드 결과는 유지된다.
# =============================================================================

# 오류 발생, 미정의 변수 사용, 파이프 중간 실패 시 즉시 중단
set -Eeuo pipefail

# ---------- 상수 ----------
readonly ROS_DISTRO_NAME="jazzy"
readonly REQUIRED_OS_VERSION="24.04"
readonly REQUIRED_CODENAME="noble"
readonly MIN_FREE_GB=30
readonly WORKSPACE_DIR="/workspace/armteam"
readonly SRC_DIR="/workspace/armteam/src"
readonly REQUIREMENTS_FILE="/workspace/armteam/requirements.txt"
readonly LOG_FILE="/workspace/setup_runpod.log"
readonly BASHRC_FILE="/root/.bashrc"
readonly ROS_SETUP_FILE="/opt/ros/jazzy/setup.bash"
readonly WS_SETUP_FILE="/workspace/armteam/install/setup.bash"
readonly SYSTEM_PYTHON="/usr/bin/python3"
readonly ROSDEP_SOURCE_FILE="/etc/ros/rosdep/sources.list.d/20-default.list"
readonly APT_SOURCE_DEB="/tmp/ros2-apt-source.deb"
readonly APT_SOURCE_RELEASE_API="https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest"
readonly APT_SOURCE_DOWNLOAD_BASE="https://github.com/ros-infrastructure/ros-apt-source/releases/download"

# 프로젝트에 필요한 패키지 목록 (추가할 패키지는 여기에 적는다)
readonly ROS_PACKAGES=(
  ros-jazzy-desktop                   # ROS 2 기본 도구, RViz
  ros-jazzy-moveit                    # MoveIt 2 motion planning
  ros-jazzy-ros-gz                    # Gazebo Harmonic 및 ROS 연동
  ros-jazzy-gz-ros2-control           # Gazebo에서 ros2_control 사용
  ros-jazzy-ros2-control              # 제어 프레임워크
  ros-jazzy-ros2-controllers          # 표준 controller 모음
  ros-jazzy-xacro                     # 로봇 모델(URDF) 매크로
  ros-jazzy-robot-state-publisher     # 로봇 TF 발행
  ros-jazzy-joint-state-publisher-gui # 관절 수동 조작
  ros-jazzy-rmw-cyclonedds-cpp        # MoveIt에서 흔히 쓰는 DDS 구현
  ros-dev-tools                       # colcon, rosdep 등 개발 도구
)
# 모니터가 없는 Pod에서 렌더링하고 브라우저로 화면을 보기 위한 도구
readonly HEADLESS_PACKAGES=(libegl1 mesa-utils xvfb x11vnc novnc websockify)
readonly BASE_PACKAGES=(ca-certificates curl git locales lsb-release python3-pip software-properties-common)

# 어느 줄에서 실패했는지 알려 준다
on_error() {
  echo "[ERROR] line $1 에서 실패했습니다. 전체 로그: ${LOG_FILE}" >&2
}
trap 'on_error $LINENO' ERR

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

# 설치를 시작하기 전에 실패할 조건을 미리 걸러 낸다
check_prerequisites() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "[ERROR] root 권한이 필요합니다." >&2
    return 1
  fi

  # ROS 2 Jazzy의 apt 패키지는 Ubuntu 24.04용이므로 다른 버전에서는 설치되지 않는다
  local os_version
  os_version="$(. /etc/os-release && echo "${VERSION_ID}")"
  if [[ "${os_version}" != "${REQUIRED_OS_VERSION}" ]]; then
    echo "[ERROR] Ubuntu ${REQUIRED_OS_VERSION}이 필요합니다 (현재: ${os_version})." >&2
    echo "        Pod 이미지를 ubuntu2404 태그로 다시 만드세요. 예: runpod/base:*-ubuntu2404" >&2
    return 1
  fi

  if [[ ! -d "${WORKSPACE_DIR}" ]]; then
    echo "[ERROR] ${WORKSPACE_DIR} 가 없습니다. /workspace 아래에 저장소를 clone하세요." >&2
    return 1
  fi

  # apt 패키지는 컨테이너 디스크(/)에 설치된다
  local free_gb
  free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
  if (( free_gb < MIN_FREE_GB )); then
    echo "[ERROR] 디스크 여유 공간 부족: ${free_gb}GB (최소 ${MIN_FREE_GB}GB)." >&2
    echo "        Pod의 container disk를 늘려서 다시 만드세요." >&2
    return 1
  fi
}

install_base_packages() {
  log "기본 패키지 설치"
  apt-get update
  apt-get install -y "${BASE_PACKAGES[@]}"
  # ROS 일부 도구는 UTF-8 locale을 전제로 한다
  locale-gen en_US.UTF-8
  update-locale LANG=en_US.UTF-8
  export LANG=en_US.UTF-8
}

add_ros_apt_source() {
  log "ROS 2 apt 저장소 등록"
  add-apt-repository -y universe

  # 저장소 설정 패키지의 최신 버전을 찾아 설치한다 (공식 설치 문서와 같은 방식)
  local version
  version="$(curl -fsSL "${APT_SOURCE_RELEASE_API}" | grep -F '"tag_name"' | awk -F'"' '{print $4}')"
  if [[ -z "${version}" ]]; then
    echo "[ERROR] ros-apt-source 버전을 찾지 못했습니다. GitHub API 제한일 수 있습니다." >&2
    return 1
  fi
  curl -fsSL -o "${APT_SOURCE_DEB}" \
    "${APT_SOURCE_DOWNLOAD_BASE}/${version}/ros2-apt-source_${version}.${REQUIRED_CODENAME}_all.deb"
  apt-get install -y "${APT_SOURCE_DEB}"
  apt-get update
}

install_ros_stack() {
  log "ROS 2, MoveIt 2, Gazebo, headless 도구 설치 (시간이 오래 걸립니다)"
  apt-get install -y "${ROS_PACKAGES[@]}" "${HEADLESS_PACKAGES[@]}"
}

# ROS의 setup.bash는 미정의 변수를 참조하므로 source하는 동안만 set -u를 끈다
source_ros() {
  set +u
  # shellcheck disable=SC1090
  source "${ROS_SETUP_FILE}"
  set -u
}

# requirements.txt가 있을 때만 설치한다. ROS 노드가 쓰는 시스템 Python에 넣어야 import된다
install_python_requirements() {
  if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
    log "requirements.txt 없음: Python 패키지 설치 건너뜀"
    return 0
  fi
  log "Python 패키지 설치"
  "${SYSTEM_PYTHON}" -m pip install --break-system-packages -r "${REQUIREMENTS_FILE}"
}

# src/ 아래에 ROS 패키지가 있을 때만 의존성 설치와 빌드를 수행한다
build_workspace() {
  if [[ -z "$(find "${SRC_DIR}" -name package.xml -print -quit 2>/dev/null)" ]]; then
    log "${SRC_DIR} 에 ROS 패키지 없음: 빌드 건너뜀"
    return 0
  fi
  log "rosdep 의존성 설치"
  # rosdep은 최초 1회 init이 필요하다. 이미 되어 있으면 init이 실패하므로 건너뛴다
  if [[ ! -f "${ROSDEP_SOURCE_FILE}" ]]; then
    rosdep init
  fi
  rosdep update --rosdistro "${ROS_DISTRO_NAME}"
  rosdep install --from-paths "${SRC_DIR}" --ignore-src -y --rosdistro "${ROS_DISTRO_NAME}"

  log "colcon build"
  # colcon은 현재 디렉터리에 build/install/log를 만들므로 서브셸에서 이동한다
  (cd "${WORKSPACE_DIR}" && colcon build --symlink-install)
}

# 새 터미널에서도 ros2, gz 명령을 바로 쓰도록 등록한다 (중복 등록 방지)
register_shell_env() {
  log "${BASHRC_FILE} 에 환경 등록"
  local line
  for line in \
    "source ${ROS_SETUP_FILE}" \
    "[ -f ${WS_SETUP_FILE} ] && source ${WS_SETUP_FILE}" \
    "export LANG=en_US.UTF-8"; do
    grep -qxF "${line}" "${BASHRC_FILE}" 2>/dev/null || echo "${line}" >> "${BASHRC_FILE}"
  done
}

# 명령이 실제로 동작하는지 확인한다
verify_install() {
  log "설치 검증"
  command -v ros2 > /dev/null
  ros2 pkg prefix moveit_ros_move_group > /dev/null
  ros2 pkg prefix ros_gz_sim > /dev/null
  gz sim --versions
  log "ROS_DISTRO=${ROS_DISTRO}"

  # GPU는 없어도 설치에는 지장이 없지만 최종 시뮬에는 필요하므로 경고만 한다
  if command -v nvidia-smi > /dev/null; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  else
    log "[WARN] nvidia-smi 없음: GPU Pod가 아닐 수 있습니다."
  fi
}

main() {
  check_prerequisites
  export DEBIAN_FRONTEND=noninteractive

  install_base_packages
  add_ros_apt_source
  install_ros_stack
  source_ros
  install_python_requirements
  build_workspace
  register_shell_env
  verify_install

  log "완료. 새 터미널을 열거나 다음을 실행하세요: source ${BASHRC_FILE}"
}

# 로그 파일 경로(/workspace)가 없으면 tee가 실패하므로 먼저 확인한다
if [[ ! -d "/workspace" ]]; then
  echo "[ERROR] /workspace 가 없습니다." >&2
  exit 1
fi
main 2>&1 | tee "${LOG_FILE}"
