#!/bin/bash

systemctl="$(command -v systemctl)"

CMD="$1"
shift
args=""
if [ $# -gt 0 ]; then
    args="$(printf "%q " "$@")"
fi

case "$CMD" in
    snapcraft|/snap/bin/snapcraft)
        CMD="snap run snapcraft"
        stdin_mode=null
        ;;
esac

. /etc/lsb-release
if [ -z "$USE_SNAPCRAFT_CHANNEL" ]; then
    case "$DISTRIB_CODENAME" in
        xenial)
            # core/xenial disabled in snapcraft 5+.
            USE_SNAPCRAFT_CHANNEL="4.x/stable"
            ;;
        bionic)
            # core18/bionic disabled in snapcraft 6+.
            USE_SNAPCRAFT_CHANNEL="5.x/stable"
            ;;
        *)
            USE_SNAPCRAFT_CHANNEL="latest/stable"
            ;;
    esac
else
    case "$USE_SNAPCRAFT_CHANNEL" in
        stable|candidate|beta|edge)
            USE_SNAPCRAFT_CHANNEL="latest/$USE_SNAPCRAFT_CHANNEL"
            ;;
    esac
fi

if [ ! -e /var/lib/apt/lists ]; then
    apt-get update
fi

cat > /usr/local/bin/docker_commandline.sh <<EOF
#!/bin/bash
# Default environment variables
export SNAPCRAFT_VERBOSITY_LEVEL=verbose

# Recreate the initial environment from docker run
$(export -p)

# Force these environment variables
export PATH="/snap/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SNAPCRAFT_BUILD_ENVIRONMENT=host
export SNAPCRAFT_MANAGED_MODE=y

# Run the command
echo "Executing: '$CMD $args'"
$CMD $args
/bin/systemctl exit \$?
EOF
chmod +x /usr/local/bin/docker_commandline.sh

cat > /etc/systemd/system/docker-exec.service <<EOF
[Unit]
Description=Docker commandline
Wants=snapd.seeded.service
After=snapd.service snapd.socket snapd.seeded.service

[Service]
ExecStartPre=/bin/bash -c '/usr/bin/snap install snapcraft --classic --channel $USE_SNAPCRAFT_CHANNEL < /dev/null'
ExecStart=/usr/local/bin/docker_commandline.sh
Environment="SNAPPY_LAUNCHER_INSIDE_TESTS=true"
Environment="LANG=C.UTF-8"
Restart=no
Type=oneshot
StandardInput=tty
StandardOutput=tty
StandardError=tty
WorkingDirectory=$PWD

[Install]
WantedBy=default.target
EOF

"$systemctl" enable docker-exec.service

if [ "$DISTRIB_CODENAME" = "xenial" ]; then
    if grep -q cgroup2 /proc/mounts; then
        echo "This container is incompatible with cgroups2. Refusing to continue."
        echo "You can try re-running this container with '--tmpfs /sys/fs/cgroup' as a possible workaround."
        echo "The workaround may not work on all systems, and will screw up the hosts' cgroups until a reboot of the system."
        exit 1
    fi
    mkdir /sys/fs/cgroup/systemd
    mount -t cgroup cgroup -o none,name=systemd,xattr /sys/fs/cgroup/systemd
fi

# The presence of either .dockerenv or /run/.containerenv cause snapcraft to
# incorrectly stage more than it should (e.g. libc and systemd). Remove them.
if [ -f /.dockerenv ]; then
    rm -f /.dockerenv
fi
if [ -f /run/.containerenv ]; then
    umount /run/.containerenv
    rm -f /run/.containerenv
fi

if grep -q securityfs /proc/filesystems; then
    mount -o rw,nosuid,nodev,noexec,relatime securityfs -t securityfs /sys/kernel/security
fi
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /run/lock
exec /lib/systemd/systemd --system --system-unit docker-exec.service
