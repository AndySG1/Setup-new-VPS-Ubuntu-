#!/usr/bin/env bash
#
# setup-vps.sh — базовая настройка нового VPS на Ubuntu 24.04
#
# Назначение: веб-сервер (nginx/apache + сайты)
# Вход по SSH: пока по паролю (в конце скрипта — инструкция, как перейти на ключи)
# Открытые порты: 22 (SSH), 80 (HTTP), 443 (HTTPS)
#
# Запускать от root (или через sudo) сразу после первого входа на сервер:
#   chmod +x setup-vps.sh
#   sudo ./setup-vps.sh
#
set -euo pipefail

### ─────────────────────────── НАСТРОЙКИ ─────────────────────────── ###

NEW_USER="andy"             # имя нового администратора (не root)
SSH_PORT="22"               # порт SSH (можно поменять на нестандартный)
ALLOWED_TCP_PORTS=(80 443)  # какие ещё порты открыть, кроме SSH
TIMEZONE="Europe/Helsinki"  # часовой пояс сервера
ENABLE_SWAP="yes"           # создать swap-файл, если его нет
SWAP_SIZE="2G"

### ──────────────────────────────────────────────────────────────── ###

if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root (sudo ./setup-vps.sh)"
  exit 1
fi

echo "==> 1/9. Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y upgrade
apt -y dist-upgrade
apt -y autoremove --purge
apt -y autoclean

echo "==> 2/9. Установка базовых утилит"
apt install -y \
  ufw \
  fail2ban \
  unattended-upgrades \
  apt-listchanges \
  curl \
  wget \
  vim \
  htop \
  net-tools \
  ca-certificates \
  gnupg \
  lsb-release

echo "==> 3/9. Часовой пояс и время"
timedatectl set-timezone "$TIMEZONE"
systemctl enable --now systemd-timesyncd || true

echo "==> 4/9. Создание нового пользователя с sudo (вместо root)"
if id "$NEW_USER" &>/dev/null; then
  echo "Пользователь $NEW_USER уже существует, пропускаю"
else
  adduser --gecos "" "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
  # копируем authorized_keys, если у root уже есть ключи (например, добавлены хостером)
  if [[ -f /root/.ssh/authorized_keys ]]; then
    mkdir -p /home/"$NEW_USER"/.ssh
    cp /root/.ssh/authorized_keys /home/"$NEW_USER"/.ssh/authorized_keys
    chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.ssh
    chmod 700 /home/"$NEW_USER"/.ssh
    chmod 600 /home/"$NEW_USER"/.ssh/authorized_keys
    echo "SSH-ключи root скопированы пользователю $NEW_USER"
  fi
fi

echo "==> 5/9. Настройка firewall (UFW)"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}"/tcp comment 'SSH'
for port in "${ALLOWED_TCP_PORTS[@]}"; do
  ufw allow "${port}"/tcp comment 'web'
done
ufw --force enable
ufw status verbose

echo "==> 6/9. Настройка SSH"
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

# запрет входа под root
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
# ограничение попыток входа
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 4/' "$SSHD_CONFIG"
# порт SSH (если меняли на нестандартный)
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
# отключаем малополезные фичи
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$SSHD_CONFIG"

# ПАРОЛЬНАЯ аутентификация оставлена включённой по вашему выбору.
# Как только добавите SSH-ключ и проверите вход по нему — обязательно
# отключите пароли (см. инструкцию в конце скрипта / в README).
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"

sshd -t && systemctl restart ssh

echo "==> 7/9. Настройка fail2ban (защита SSH от перебора паролей)"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "==> 8/9. Автоматические обновления безопасности"
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades

echo "==> 9/9. Базовая защита сети (sysctl) и swap"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# защита от IP-спуфинга
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# игнорировать ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
# защита от SYN-flood
net.ipv4.tcp_syncookies = 1
# отключить source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
# логировать "странные" пакеты
net.ipv4.conf.all.log_martians = 1
EOF
sysctl --system

if [[ "$ENABLE_SWAP" == "yes" && ! -f /swapfile ]]; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

echo
echo "════════════════════════════════════════════════════════════"
echo " Готово! Что сделано:"
echo "  • Система обновлена, включены автообновления безопасности"
echo "  • Создан пользователь: $NEW_USER (в группе sudo)"
echo "  • UFW: разрешены порты ${SSH_PORT}(SSH), ${ALLOWED_TCP_PORTS[*]}, всё остальное закрыто"
echo "  • fail2ban защищает SSH от перебора паролей"
echo "  • root по SSH отключён, вход по паролю пока разрешён"
echo "════════════════════════════════════════════════════════════"
echo
echo "ВАЖНО — следующий шаг: настройте вход по SSH-ключу и отключите пароль."
echo "См. INSTRUCTIONS.md, раздел «Переход на SSH-ключи»."
