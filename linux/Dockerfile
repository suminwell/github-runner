# Runtime image for Docker mode: the Shell supervisor, the official Runner and jobs.
# Built locally by linux/docker.sh; the Runner itself is mounted from the host.
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}
ARG UBUNTU_MIRROR=
ARG DOCKER_MIRROR=https://download.docker.com
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN set -eux; \
    if [ -n "$UBUNTU_MIRROR" ]; then \
        sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#${UBUNTU_MIRROR}/ubuntu/#g; s#https?://ports\.ubuntu\.com/ubuntu-ports/?#${UBUNTU_MIRROR}/ubuntu-ports/#g" /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl git git-lfs gnupg jq procps tar gzip bzip2 xz-utils zip unzip \
        openssh-client rsync wget file python3 util-linux sudo \
        libicu70 libkrb5-3 libssl3 liblttng-ust1 zlib1g; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL --retry 3 "$DOCKER_MIRROR/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s/linux/ubuntu jammy stable\n' "$(dpkg --print-architecture)" "$DOCKER_MIRROR" > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*
