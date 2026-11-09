# armteam RunPod image: Ubuntu 24.04 + ROS 2 Jazzy + MoveIt 2 + Gazebo + browser desktop.
#
# Built automatically by .github/workflows/docker-image.yml and pushed to
#   ghcr.io/ddongs068/armteam:latest
# Use that image in a RunPod template so every new pod starts with the full environment.
#
# Local build:  docker build -t armteam .

# RunPod's official Ubuntu 24.04 base (no CUDA). Its /start.sh runs SSH, Jupyter
# and the web terminal, so the pod behaves like any official RunPod template.
FROM runpod/base:1.0.3-ubuntu2404

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    ROS_DISTRO=jazzy \
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

# Same package list and installer the team uses on a plain pod.
COPY requirement.txt run_requirement.sh /opt/armteam/
RUN bash /opt/armteam/run_requirement.sh --image

COPY docker/pod_start.sh /opt/armteam/pod_start.sh
RUN chmod +x /opt/armteam/pod_start.sh

# 6080: browser desktop (noVNC). 22 (SSH) and 8888 (Jupyter) come from the base image.
EXPOSE 6080

CMD ["/opt/armteam/pod_start.sh"]
