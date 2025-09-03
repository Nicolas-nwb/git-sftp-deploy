FROM debian:bookworm-slim

# Installation OpenSSH server
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server ca-certificates bash coreutils; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /var/www/html /home/deploy/.ssh /keys

# Créer l'utilisateur 'deploy'
RUN useradd -m -d /home/deploy -s /bin/bash deploy && \
    chown -R deploy:deploy /home/deploy /var/www/html && \
    chmod 700 /home/deploy/.ssh

# Config SSH minimale
RUN sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -ri 's|^#?Subsystem\s\+sftp.*|Subsystem sftp /usr/lib/openssh/sftp-server|' /etc/ssh/sshd_config && \
    printf '\nUseDNS no\nPubkeyAuthentication yes\nAuthorizedKeysFile .ssh/authorized_keys\n' >> /etc/ssh/sshd_config

COPY docker/sftp/entrypoint.sh /entrypoint.sh
# Optionnel: copier un seed statique minimal (peut rester vide)
COPY --chown=deploy:deploy tests/remote-www/ /var/www/html/
# Clé publique embarquée comme authorized_keys
COPY --chown=deploy:deploy docker/keys/id_ed25519.pub /home/deploy/.ssh/authorized_keys
RUN chmod 600 /home/deploy/.ssh/authorized_keys && chmod +x /entrypoint.sh

EXPOSE 22
CMD ["/entrypoint.sh"]
