FROM debian:bookworm-slim

# Outils: git, ssh client, bash, jq (utile debug), nano
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git openssh-client ca-certificates bash coreutils sed jq nano; \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace
WORKDIR /workspace

# Préparer .ssh
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Copier le projet et la config SSH/clé privée dans l'image
COPY . /workspace
COPY docker/dev/ssh_config /root/.ssh/config
COPY docker/keys/id_ed25519 /root/.ssh/id_ed25519
RUN chmod 600 /root/.ssh/id_ed25519 /root/.ssh/config

COPY docker/dev/sftp-wrapper.sh /usr/local/bin/sftp
RUN chmod +x /usr/local/bin/sftp

CMD ["bash", "-lc", "echo 'dev container ready'; tail -f /dev/null"]
