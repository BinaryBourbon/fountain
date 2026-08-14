# Reference Daytona snapshot for Fountain sandboxes.
#
# Build and push with the Daytona CLI from this directory:
#
#     daytona snapshot create fountain --dockerfile Dockerfile
#
# then point the instance at it with DAYTONA_SNAPSHOT=fountain.
#
# Recreates the Sprites base-image shape the provisioning pipeline assumes:
# a `sprite` user with passwordless sudo, HOME=/home/sprite, ~/.local/bin on
# PATH, bash, git, node/npm/npx, bun, and the agent CLIs preinstalled.
# Daytona requires AMD64 images.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      bash ca-certificates curl git gnupg sudo unzip xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y -qq nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /home/sprite -s /bin/bash sprite && \
    echo "sprite ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sprite && \
    chmod 440 /etc/sudoers.d/sprite

USER sprite
WORKDIR /home/sprite
ENV HOME=/home/sprite
ENV PATH=/home/sprite/.local/bin:/home/sprite/.bun/bin:$PATH

RUN mkdir -p /home/sprite/.local/bin && \
    curl -fsSL https://bun.sh/install | bash

RUN sudo npm install -g --no-progress --silent \
      @anthropic-ai/claude-code \
      @openai/codex \
      @google/gemini-cli && \
    /home/sprite/.bun/bin/bun install -g opencode-ai
