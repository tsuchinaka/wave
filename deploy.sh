#!/usr/bin/env bash

set -e

# Incremental by default: a full clean build is only needed after changing
# shared build configuration, frameworks, or when Theos' dependency state is
# suspected to be stale. Use ./deploy.sh --clean for that case.
WAVE_CLEAN_BUILD=0
WAVE_ARCHS="${WAVE_ARCHS:-}"
if [ "${1:-}" = "--clean" ]; then
    WAVE_CLEAN_BUILD=1
    shift
fi
if [ "${1:-}" = "--arch" ]; then
    WAVE_ARCHS="${2:-}"
    shift 2
    if [ -z "$WAVE_ARCHS" ]; then
        printf '%s\n' "Error: --arch requires armv7 or armv7s" >&2
        exit 2
    fi
fi
if [ "$#" -gt 0 ]; then
    printf '%s\n' "Usage: ./deploy.sh [--clean] [--arch armv7|armv7s]" >&2
    exit 2
fi

# dpkg-deb rejects Theos' staging DEBIAN directory when an inherited restrictive
# umask creates it as 700. Keep generated package metadata traversable.
umask 022

export THEOS="${THEOS:-/home/main/theos}"
export THEOS_DEVICE_IP="192.168.1.8"
export THEOS_DEVICE_USER="root"
export SSHPASS="alpine"

# Reuse compiler results across clean builds when ccache is available. The
# ccache wrappers provide clang/clang++ transparently on this host.
if command -v ccache >/dev/null 2>&1 && [ -d "/usr/lib/ccache/bin" ]; then
    export PATH="/usr/lib/ccache/bin:$PATH"
fi

if ! command -v sshpass >/dev/null 2>&1; then
    printf '%s\n' "Error: sshpass is required. Install it with: sudo apt install sshpass" >&2
    exit 1
fi

wrapper_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$wrapper_dir"
}
trap cleanup EXIT

cat > "$wrapper_dir/ssh" <<'EOF'
#!/usr/bin/env bash
exec sshpass -e /usr/bin/ssh -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa "$@"
EOF

cat > "$wrapper_dir/scp" <<'EOF'
#!/usr/bin/env bash
exec sshpass -e /usr/bin/scp -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa "$@"
EOF

chmod 700 "$wrapper_dir/ssh" "$wrapper_dir/scp"
export PATH="$wrapper_dir:$PATH"

if [ "$WAVE_CLEAN_BUILD" -eq 1 ]; then
    make clean
fi
if [ -n "$WAVE_ARCHS" ]; then
    make ARCHS="$WAVE_ARCHS" -j4
else
    make -j4
fi

# The linker creates the application executable with the current user's
# restrictive mode on this host. SpringBoard launches apps as mobile, so the
# executable must be readable and executable by non-root users.
# Theos uses .theos/obj/debug for debug builds and .theos/obj/<arch> for
# FINALPACKAGE builds. SpringBoard launches the app as mobile, so every
# resulting executable must be readable and executable by non-root users.
find .theos/obj -type f -path '*/wave.app/wave' -exec chmod 755 {} +
# The legacy Theos staging tree can retain restrictive permissions from an
# earlier build, which makes dpkg-deb reject the DEBIAN directory.
chmod 755 .theos/_ .theos/_/DEBIAN .theos/_/Applications 2>/dev/null || true
chmod 644 .theos/_/DEBIAN/control 2>/dev/null || true

if [ -n "$WAVE_ARCHS" ]; then
    make ARCHS="$WAVE_ARCHS" -j4 package install
else
    make -j4 package install
fi
