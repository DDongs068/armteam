# armteam

Robot simulation project built with ROS 2 Jazzy, MoveIt 2, and Gazebo Harmonic.

## Final Goal

> **TODO:** Add the final assignment and its completion criteria from the team's project page.

## Tasks

> **TODO:** Add the assignment's required tasks from the team's project page.

Simulation workflow:

- [ ] Set up an Ubuntu 24.04 VM for development and quick simulation checks
- [ ] Confirm that Gazebo renders correctly on a Runpod GPU Pod
- [ ] Integrate all team code in this repository
- [ ] Run the final simulation on Runpod

## Running on Runpod

### 1. Create a Pod

- **Image:** an Ubuntu 24.04 image, such as `runpod/base:1.5.0-ubuntu2404`
- **Container disk:** at least 40 GB
- **Volume mount path:** `/workspace`

### 2. Install everything

```bash
cd /workspace
git clone https://github.com/DDongs068/armteam.git
bash /workspace/armteam/setup_runpod.sh
source /root/.bashrc
```

The script installs the following, then verifies the installation:

- ROS 2 Jazzy, MoveIt 2, Gazebo Harmonic, and `ros2_control`
- Tools for headless rendering and browser-based viewing
- Python packages from `requirements.txt`, if the file exists
- ROS dependencies for packages in `src/`, which it then builds with `colcon`, if any exist

The log is saved to `/workspace/setup_runpod.log`.

### 3. On a new Pod

Packages installed with `apt` are lost when a Pod is replaced. Files in `/workspace` remain on a network volume, so run the script again without cloning:

```bash
bash /workspace/armteam/setup_runpod.sh
```

### Adding dependencies

| Dependency | Where to add it |
|---|---|
| Used by a ROS package | That package's `package.xml` |
| Python package | `requirements.txt` in the repository root |
| Other system or ROS package | The package lists at the top of `setup_runpod.sh` |

Build artifacts are specific to each CPU architecture, so commit source code only. The script rebuilds it on Runpod.
