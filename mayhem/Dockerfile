# syntax=docker/dockerfile:1.7
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# CaDiCaL / CaDiBaCk are fetched by upstream's CMake from GitHub at configure time (unpinned
# branches); pin them here, in-image, so build.sh runs offline and re-runs identically.
USER root
RUN [ -z "$SOURCE_DATE_EPOCH" ] || repro-sources-list.sh; \
    apt-get update && apt-get install -yq --no-install-recommends libgmp-dev \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/toolchains/deps \
 && git clone -q https://github.com/meelgroup/cadical /opt/toolchains/deps/cadical \
 && git -C /opt/toolchains/deps/cadical checkout -q 818c9562f114b315a9246ced943b66b60b38e8fb \
 && git clone -q https://github.com/meelgroup/cadiback /opt/toolchains/deps/cadiback \
 && git -C /opt/toolchains/deps/cadiback checkout -q 445ddc2f2b5e54421af64e0652c2eb8444175322 \
 && chown -R 2000:2000 /opt/toolchains/deps

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
