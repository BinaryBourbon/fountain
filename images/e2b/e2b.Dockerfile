# Reference E2B template for Fountain sandboxes.
#
# Build with the E2B CLI from this directory:
#
#     e2b template build --name fountain --dockerfile e2b.Dockerfile
#
# then point the instance at it with E2B_TEMPLATE=fountain.
#
# The provisioning pipeline assumes the Sprites base-image shape: a `sprite`
# user with passwordless sudo, HOME=/home/sprite, ~/.local/bin on PATH, bash,
# git, node/npm/npx, bun, and the agent CLIs preinstalled. Recreating that
# shape here means zero provisioning-code changes per provider.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      bash ca-certificates curl git gnupg sudo unzip xz-utils && \
    rm -rf /var/lib/apt/lists/*

# Node 22 (npm/npx ride along) and bun.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y -qq nodejs && \
    rm -rf /var/lib/apt/lists/*

# The sprite user: passwordless sudo, the home layout the pipeline writes to.
RUN useradd -m -d /home/sprite -s /bin/bash sprite && \
    echo "sprite ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sprite && \
    chmod 440 /etc/sudoers.d/sprite

USER sprite
WORKDIR /home/sprite
ENV HOME=/home/sprite
ENV PATH=/home/sprite/.local/bin:/home/sprite/.bun/bin:$PATH

RUN mkdir -p /home/sprite/.local/bin && \
    curl -fsSL https://bun.sh/install | bash

# The agent CLIs the runtimes expect on PATH. Versions float with the image
# build; the ACP adapters themselves are pinned and installed at provision
# time by Fountain.Runtimes.ACP.install/3.
RUN sudo npm install -g --no-progress --silent \
      @anthropic-ai/claude-code \
      @openai/codex \
      @google/gemini-cli && \
    /home/sprite/.bun/bin/bun install -g opencode-ai
