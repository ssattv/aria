FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl jq python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# NOTE: github.com/sst/opencode redirects to github.com/anomalyco/opencode
# Release assets are tarballs containing a single 'opencode' binary
ARG OPENCODE_VERSION=latest
RUN curl -fsSL \
      "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-x64.tar.gz" \
      | tar -xz -C /usr/local/bin opencode \
    && chmod +x /usr/local/bin/opencode

COPY gitlab-mr-changed-files.sh \
     gitlab-mr-post-comments.sh \
     generate-opencode-config.sh \
     generate-review-comments.sh \
     resolve-profiles.sh \
     opencode.json.template \
     /opt/aria/

RUN chmod +x /opt/aria/*.sh

ENV PATH="/opt/aria:$PATH"
