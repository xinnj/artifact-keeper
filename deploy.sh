#!/bin/bash

# Deploy script for Artifact Keeper
# This script:
# 1. Rsync project to remote server
# 2. Run fmt + clippy + unit tests on the remote server
# 3. Build and push Docker image (linux/amd64 via buildx)
# 4. Restart Kubernetes deployment
#
# Set SKIP_TESTS=1 to skip step 2 (fast deploys).

set -e  # Exit on error

# Load configuration from env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env.remote.local"

SSH_OPTS="-o StrictHostKeyChecking=no -p ${REMOTE_PORT}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}



# Step 1: Rsync project to remote server
step1_rsync() {
    echo_info "Step 1: Syncing project to remote server..."
    
    # Create remote directory
    echo_info "Creating remote directory..."
    ssh ${SSH_OPTS} \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p ${REMOTE_PATH}"
    
    # Sync project files to remote server using rsync
    echo_info "Syncing files to remote server (this may take a moment)..."
    # Do NOT exclude *.md: backend/src/models/format_handler.rs `include_str!`s
    # docs/security/scan-on-proxy.md, so excluding Markdown makes the remote
    # clippy/test build fail with "couldn't read ... scan-on-proxy.md".
    rsync -avz --delete \
        --exclude='.git' \
        --exclude='target' \
        --exclude='.DS_Store' \
        --exclude='deploy.sh' \
        -e "ssh ${SSH_OPTS}" \
        ./ \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"
    
    echo_info "Project synced successfully!"
}

# Step 2: Run fmt + clippy + unit tests on the remote server
step2_test() {
    # Fast deploys: SKIP_TESTS=1 ./deploy.sh
    if [ "${SKIP_TESTS:-0}" = "1" ] || [ "${SKIP_TESTS:-0}" = "true" ]; then
        echo_warn "Skipping tests (SKIP_TESTS is set)."
        return 0
    fi

    echo_info "Step 2: Running fmt + clippy + unit tests on remote server..."

    # Tests run natively on the remote host, so they need the Rust toolchain
    # installed there (the Docker image has its own toolchain, not reusable here).
    if ! ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
        '[ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"; command -v cargo >/dev/null 2>&1'; then
        echo_error "Rust toolchain (cargo) is not installed on the remote server."
        echo_error "Install rustup there, or set SKIP_TESTS=1 to deploy without tests."
        exit 1
    fi

    # Several inline tests require nextest's one-process-per-test isolation
    # (process-global env/OnceLock state), so `cargo test` cannot run them.
    if ! ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
        '[ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"; command -v cargo-nextest >/dev/null 2>&1'; then
        echo_error "cargo-nextest is not installed on the remote server."
        echo_error "Install it (cargo install cargo-nextest --locked), or set SKIP_TESTS=1."
        exit 1
    fi

    # The test suites need a database; CI provisions a fresh one per leg.
    if [ -z "${TEST_DATABASE_URL:-}" ]; then
        echo_error "TEST_DATABASE_URL is not set in .env.remote.local."
        echo_error "Add the test database URL, e.g. postgresql://postgres:<pw>@127.0.0.1:35432/mydb."
        exit 1
    fi

    # The lib-test rustc peaks near 15.5 GiB. This host has 14 GiB RAM plus a
    # 16 GiB swapfile; debuginfo and incremental state are off to lower the peak.
    # `sqlx database reset` drops/re-creates TEST_DATABASE_URL's database and
    # re-runs migrations, so leftover rows/locks cannot flake the global-state
    # suites (the CI provisions a fresh database per leg for the same reason).
    local test_env="SQLX_OFFLINE=true CARGO_BUILD_JOBS=4 CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0 JWT_SECRET=ci-coverage-secret-at-least-32-bytes-long-for-tests AK_TESTS_REQUIRE_DB=1 DATABASE_URL='${TEST_DATABASE_URL}'"

    if ! ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
        "source ~/.cargo/env && cd ${REMOTE_PATH} && export ${test_env} \
         && cargo fmt --check \
         && cargo clippy --workspace --all-targets -- -D warnings \
         && sqlx database reset -y --source backend/migrations \
         && cargo nextest run --workspace --lib --jobs 4 --no-fail-fast"; then
        echo_error "Pre-deploy checks failed (fmt/clippy/test). Fix them, or set SKIP_TESTS=1 to bypass."
        exit 1
    fi

    echo_info "Tests passed successfully!"
}

# Step 3: Build and push Docker image
step3_build_push() {
    echo_info "Step 3: Building and pushing Docker image..."

    # Ensure docker buildx is available on the remote server
    echo_info "Checking docker buildx on remote server..."
    ssh ${SSH_OPTS} \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "docker buildx version" || {
        echo_error "docker buildx is not available on remote server. Please install Docker Buildx first."
        exit 1
    }

    local build_args=""
    [ -n "$GIT_SHA" ] && build_args="$build_args --build-arg GIT_SHA=$GIT_SHA"
    [ -n "$APP_VERSION" ] && build_args="$build_args --build-arg APP_VERSION=$APP_VERSION"
    [ -n "$CARGO_FEATURES" ] && build_args="$build_args --build-arg CARGO_FEATURES=$CARGO_FEATURES"
    [ -n "$CARGO_BUILD_JOBS" ] && build_args="$build_args --build-arg CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"

    # The build host keeps its proxy settings in ~/.profile, and
    # `ssh host 'command'` starts a NON-login shell that never reads it.
    # BuildKit resolves the `# syntax=docker/dockerfile:1` frontend image with
    # the buildx CLI's own HTTP client, which also ignores the Docker daemon's
    # systemd proxy settings, so without sourcing the profile the build fails
    # before any stage runs:
    #   failed to fetch anonymous token ... dial tcp ...: i/o timeout
    # RUN steps get the proxy from ~/.docker/config.json and need nothing here.
    echo_info "Building and pushing Docker image: ${DOCKER_IMAGE} (linux/amd64)"
    ssh ${SSH_OPTS} \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        ". ~/.profile >/dev/null 2>&1 || true; cd ${REMOTE_PATH} && docker buildx build --platform linux/amd64 -f docker/Dockerfile.backend -t ${DOCKER_IMAGE} --push $build_args ."

    echo_info "Docker image built and pushed successfully!"
}

# Step 4: Restart Kubernetes deployment via rolling restart
K8S_WAIT_TIMEOUT="${K8S_WAIT_TIMEOUT:-120}"

step4_restart_k8s() {
    echo_info "Step 4: Restarting Kubernetes deployment..."

    # Check if kube config file exists
    if [ ! -f "$KUBE_CONFIG" ]; then
        echo_error "Kube config file not found: ${KUBE_CONFIG}"
        exit 1
    fi

    local KCTL="kubectl --kubeconfig=$KUBE_CONFIG -n $K8S_NAMESPACE"

    echo_info "Triggering rolling restart for deployment ${K8S_DEPLOYMENT} in namespace ${K8S_NAMESPACE}..."
    $KCTL rollout restart deployment "$K8S_DEPLOYMENT"

    # Wait for rollout to complete
    echo_info "Waiting for rollout to complete (timeout: ${K8S_WAIT_TIMEOUT}s)..."
    if $KCTL rollout status deployment "$K8S_DEPLOYMENT" --timeout="${K8S_WAIT_TIMEOUT}s"; then
        echo_info "Deployment ${K8S_DEPLOYMENT} restarted successfully!"
    else
        echo_error "Rollout for deployment ${K8S_DEPLOYMENT} failed or timed out"
        exit 1
    fi
}

# Main execution
main() {
    echo_info "=========================================="
    echo_info "Starting deployment of Artifact Keeper"
    echo_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        echo_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi

    # Execute steps
    step1_rsync
    echo ""
    
    step2_test
    echo ""

    step3_build_push
    echo ""
    
    step4_restart_k8s
    echo ""
    
    echo_info "=========================================="
    echo_info "Deployment completed successfully!"
    echo_info "=========================================="
}

# Run main function
main "$@"
