# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base): debian + clang/llvm + libFuzzer/afl++ + identities + build ENV.
# This only adds w3m's two build dependencies (Boehm GC, ncurses) and the per-commit build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never an ENV — an empty value breaks clang.
ARG SOURCE_DATE_EPOCH
# Sanitizer override: undefaulted ARG lets the base ENV (ASan+UBSan, halting) flow through unless
# --build-arg'd. An explicit empty value builds with NO sanitizers (natural-crash repro build).
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instruments the TEST build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# w3m's own build dependencies: Boehm GC (its allocator, and what the fuzz harness initializes) and
# ncurses (terminal library `--with-termlib`, linked into the `w3m` binary unconditionally). Both are
# pinned apt packages from the base's snapshot — no fetch-from-source needed (unlike vorbis/libogg,
# there's no reason to build these instrumented from source: the fuzzed code is w3m's own charset/HTML
# conversion layer, not GC/ncurses internals).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update \
 && apt-get install -yq --no-install-recommends libgc-dev libncurses-dev \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds out-of-tree and drops the targets in /mayhem.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run w3m's own functional suite at build time (tests/run_tests: HTML->text conversion golden-diff
# tests). A failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
