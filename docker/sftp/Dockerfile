FROM debian:bookworm-slim

# Installation OpenSSH server
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server ca-certificates bash; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /var/www/html /home/deploy/.ssh

# Créer l'utilisateur 'deploy'
RUN useradd -m -d /home/deploy -s /bin/bash deploy && \
    chown -R deploy:deploy /home/deploy /var/www/html && \
    chmod 700 /home/deploy/.ssh

# Config SSH minimale
RUN sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -ri 's|^#?Subsystem\s\+sftp.*|Subsystem sftp /usr/lib/openssh/sftp-server|' /etc/ssh/sshd_config && \
    printf '\nUseDNS no\nPubkeyAuthentication yes\nAuthorizedKeysFile .ssh/authorized_keys\n' >> /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
CMD ["/entrypoint.sh"]
