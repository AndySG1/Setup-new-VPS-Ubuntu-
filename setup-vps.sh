#!/usr/bin/env bash
#
# setup-vps.sh — базовая настройка нового VPS на Ubuntu 24.04
#
# Назначение: веб-сервер (nginx/apache + сайты)
# Открытые порты: SSH-порт (по умолчанию 22), 80 (HTTP), 443 (HTTPS)
#
# Запускать от root (или через sudo) сразу после первого входа на сервер:
#   chmod +x setup-vps.sh
#   sudo ./setup-vps.sh
#
# Скрипт делает ВСЁ за один запуск и идемпотентен: его можно безопасно
# запускать повторно — каждый шаг сначала проверяет, не выполнен ли он уже
# (пользователь существует, пакет установлен, ключ уже добавлен и т.д.),
# и если да — просто переходит к следующему шагу, ничего не ломая.
#
# Интерактивность:
#   Если скрипт запущен в обычном терминале без флага -y/--yes, он спросит:
#     • имя нового администратора и SSH-порт
#     • использовать ли вход по SSH-ключу (и попросит вставить публичный ключ)
#     • отключать ли вход по паролю (доступно только если ключ настроен)
#     • какие дополнительные программы установить (список с номерами)
#
#   Всё это также можно задать заранее флагами/переменными окружения,
#   тогда соответствующий вопрос не будет задан:
#     -u / NEW_USER              имя пользователя
#     -p / SSH_PORT               порт SSH
#          USE_SSH_KEY=yes|no     использовать SSH-ключ
#          SSH_PUB_KEY="..."      сам публичный ключ (одной строкой)
#          DISABLE_PASSWORD_AUTH=yes|no  отключить вход по паролю
#          SELECTED_PACKAGES="1 3 6"     номера доп. пакетов через пробел
#     -y / --yes                  не задавать вопросы, использовать значения как есть
#
set -euo pipefail

### ─────────────────────────── НАСТРОЙКИ ─────────────────────────── ###

NEW_USER="${NEW_USER:-andy}"                          # имя нового администратора (не root)
SSH_PORT="${SSH_PORT:-23542}"                         # порт SSH
ALLOWED_TCP_PORTS=(80 443)                            # какие ещё порты открыть, кроме SSH
TIMEZONE="Europe/Helsinki"                            # часовой пояс сервера
ENABLE_SWAP="yes"                                     # создать swap-файл, если его нет
SWAP_SIZE="2G"

USE_SSH_KEY="${USE_SSH_KEY:-no}"                      # yes/no — настраивать вход по ключу
SSH_PUB_KEY="${SSH_PUB_KEY:-}"                        # публичный ключ, если задан заранее
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-no}"  # yes/no — отключить пароль
SELECTED_PACKAGES="${SELECTED_PACKAGES:-}"            # номера доп. пакетов, например "1 3 6"

### ──────────────────────────────────────────────────────────────── ###

usage() {
  cat <<EOF
Использование: sudo ./setup-vps.sh [-u ИМЯ_ПОЛЬЗОВАТЕЛЯ] [-p SSH_ПОРТ] [-y]

  -u, --user   имя нового администратора (по умолчанию: deploy)
  -p, --port   порт SSH (по умолчанию: 22)
  -y, --yes    не спрашивать интерактивно, использовать значения/переменные как есть
  -h, --help   показать эту справку

Остальные вопросы (SSH-ключ, отключение пароля, доп. пакеты) можно задать
заранее через переменные окружения — см. комментарий в начале файла.

Скрипт идемпотентен: повторный запуск безопасен, уже выполненные шаги
(существующий пользователь, установленные пакеты и т.п.) пропускаются.
EOF
}

SKIP_PROMPT="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user) NEW_USER="$2"; shift 2 ;;
    -p|--port) SSH_PORT="$2"; shift 2 ;;
    -y|--yes)  SKIP_PROMPT="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный параметр: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root (sudo ./setup-vps.sh)"
  exit 1
fi

INTERACTIVE="no"
if [[ "$SKIP_PROMPT" == "no" && -t 0 ]]; then
  INTERACTIVE="yes"
fi

is_pkg_installed() {
  dpkg -s "$1" &>/dev/null
}

echo "══════════════════════════════════════════════════════════════"
echo " Настройка VPS — несколько вопросов перед началом"
echo "══════════════════════════════════════════════════════════════"

if [[ "$INTERACTIVE" == "yes" ]]; then
  read -rp "Имя нового пользователя [$NEW_USER]: " input_user
  NEW_USER="${input_user:-$NEW_USER}"

  read -rp "Порт SSH [$SSH_PORT]: " input_port
  SSH_PORT="${input_port:-$SSH_PORT}"
fi

# Простая валидация
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Некорректное имя пользователя: $NEW_USER"
  exit 1
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  echo "Некорректный порт SSH: $SSH_PORT"
  exit 1
fi

if [[ "$INTERACTIVE" == "yes" ]]; then
  read -rp "Настроить вход по SSH-ключу? [Y/n]: " use_key_ans
  if [[ "$use_key_ans" =~ ^[Nn] ]]; then
    USE_SSH_KEY="no"
  else
    USE_SSH_KEY="yes"
    echo "Вставьте публичный SSH-ключ одной строкой (например, содержимое ~/.ssh/id_ed25519.pub)."
    echo "Если ключ уже добавлен хостером в root — просто нажмите Enter."
    read -rp "SSH-ключ: " SSH_PUB_KEY
  fi

  echo
  read -rp "Отключить вход по паролю после настройки? [y/N]: " disable_pw_ans
  if [[ "$disable_pw_ans" =~ ^[Yy] ]]; then
    DISABLE_PASSWORD_AUTH="yes"
  else
    DISABLE_PASSWORD_AUTH="no"
  fi
fi

if [[ "$USE_SSH_KEY" != "yes" && "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
  echo "Внимание: отключение пароля запрошено без настройки SSH-ключа."
  echo "Проверка наличия ключа будет выполнена позже — если ключа не найдётся, пароль останется включён."
fi

if [[ "$INTERACTIVE" == "yes" ]]; then
  echo
  echo "──────────────────────────────────────────────"
  echo " Дополнительное ПО (не обязательно)"
  echo "──────────────────────────────────────────────"
  echo " 1) Nginx"
  echo " 2) Docker + Docker Compose"
  echo " 3) MySQL Server"
  echo " 4) PostgreSQL"
  echo " 5) Redis"
  echo " 6) Node.js (LTS, через NodeSource)"
  echo " 7) Certbot (Let's Encrypt)"
  echo " 8) PHP-FPM"
  echo " 9) Git"
  echo "──────────────────────────────────────────────"
  read -rp "Номера нужных пакетов через пробел (например: 1 3 6), Enter — пропустить: " SELECTED_PACKAGES
fi

echo
echo "Пользователь: $NEW_USER | SSH-порт: $SSH_PORT | SSH-ключ: $USE_SSH_KEY | Отключить пароль: $DISABLE_PASSWORD_AUTH"
[[ -n "$SELECTED_PACKAGES" ]] && echo "Доп. пакеты: $SELECTED_PACKAGES"
echo "Все шаги ниже выполнятся сейчас за один прогон. Уже сделанные ранее шаги будут пропущены."
echo

echo "==> 1/11. Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y upgrade
apt -y dist-upgrade
apt -y autoremove --purge
apt -y autoclean

echo "==> 2/11. Установка базовых утилит"
BASE_PKGS=(ufw fail2ban unattended-upgrades apt-listchanges curl wget vim htop net-tools ca-certificates gnupg lsb-release)
TO_INSTALL=()
for p in "${BASE_PKGS[@]}"; do
  is_pkg_installed "$p" || TO_INSTALL+=("$p")
done
if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
  apt install -y "${TO_INSTALL[@]}"
else
  echo "Все базовые утилиты уже установлены, пропускаю"
fi

echo "==> 3/11. Часовой пояс и время"
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo '')"
if [[ "$CURRENT_TZ" == "$TIMEZONE" ]]; then
  echo "Часовой пояс уже установлен ($TIMEZONE), пропускаю"
else
  timedatectl set-timezone "$TIMEZONE"
fi
systemctl enable --now systemd-timesyncd || true

echo "==> 4/11. Создание нового пользователя с sudo (вместо root)"
if id "$NEW_USER" &>/dev/null; then
  echo "Пользователь $NEW_USER уже существует, пропускаю создание"
else
  adduser --gecos "" "$NEW_USER"
fi
if id -nG "$NEW_USER" | grep -qw sudo; then
  echo "Пользователь $NEW_USER уже в группе sudo, пропускаю"
else
  usermod -aG sudo "$NEW_USER"
fi

echo "==> 5/11. Настройка SSH-ключа"
mkdir -p /home/"$NEW_USER"/.ssh
touch /home/"$NEW_USER"/.ssh/authorized_keys

# копируем ключи root, если они уже были добавлены хостером
if [[ -f /root/.ssh/authorized_keys ]]; then
  cat /root/.ssh/authorized_keys >> /home/"$NEW_USER"/.ssh/authorized_keys
fi

# добавляем ключ, введённый вручную (если задан)
if [[ "$USE_SSH_KEY" == "yes" && -n "$SSH_PUB_KEY" ]]; then
  if [[ "$SSH_PUB_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2) ]]; then
    if grep -qF "$SSH_PUB_KEY" /home/"$NEW_USER"/.ssh/authorized_keys 2>/dev/null; then
      echo "Указанный SSH-ключ уже добавлен, пропускаю"
    else
      echo "$SSH_PUB_KEY" >> /home/"$NEW_USER"/.ssh/authorized_keys
      echo "Указанный SSH-ключ добавлен пользователю $NEW_USER"
    fi
  else
    echo "Строка не похожа на публичный SSH-ключ (должна начинаться с ssh-ed25519/ssh-rsa/ecdsa-...) — пропускаю"
  fi
fi

sort -u -o /home/"$NEW_USER"/.ssh/authorized_keys /home/"$NEW_USER"/.ssh/authorized_keys
chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.ssh
chmod 700 /home/"$NEW_USER"/.ssh
chmod 600 /home/"$NEW_USER"/.ssh/authorized_keys

KEY_PRESENT="no"
if [[ -s /home/"$NEW_USER"/.ssh/authorized_keys ]]; then
  KEY_PRESENT="yes"
fi

if [[ "$DISABLE_PASSWORD_AUTH" == "yes" && "$KEY_PRESENT" == "no" ]]; then
  echo "Ключей не найдено — отключать пароль небезопасно, оставляю вход по паролю включённым."
  DISABLE_PASSWORD_AUTH="no"
fi

echo "==> 6/11. Настройка firewall (UFW)"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}"/tcp comment 'SSH' >/dev/null
for port in "${ALLOWED_TCP_PORTS[@]}"; do
  ufw allow "${port}"/tcp comment 'web' >/dev/null
done
if ufw status | grep -q "Status: active"; then
  echo "UFW уже включён, правила обновлены"
else
  ufw --force enable
fi
ufw status verbose

echo "==> 7/11. Настройка SSH"
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 4/' "$SSHD_CONFIG"
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$SSHD_CONFIG"

if [[ "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
  echo "Вход по паролю отключён (используется только SSH-ключ)."
else
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
  echo "Вход по паролю оставлен включённым."
fi

sshd -t && systemctl restart ssh

echo "==> 8/11. Настройка fail2ban (защита SSH от перебора паролей)"
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

echo "==> 9/11. Автоматические обновления безопасности"
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

echo "==> 10/11. Базовая защита сети (sysctl) и swap"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
EOF
sysctl --system >/dev/null

if [[ "$ENABLE_SWAP" == "yes" ]]; then
  if [[ -f /swapfile ]]; then
    echo "Swap-файл уже существует, пропускаю"
  else
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  sysctl vm.swappiness=10 >/dev/null
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

echo "==> 11/11. Дополнительное ПО"

install_nginx() {
  if is_pkg_installed nginx; then
    echo "Nginx уже установлен, пропускаю"
  else
    echo "Установка Nginx..."
    apt install -y nginx
  fi
}

install_docker() {
  if command -v docker &>/dev/null; then
    echo "Docker уже установлен, пропускаю"
  else
    echo "Установка Docker + Docker Compose..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if id -nG "$NEW_USER" | grep -qw docker; then
    echo "Пользователь $NEW_USER уже в группе docker, пропускаю"
  else
    usermod -aG docker "$NEW_USER" || true
    echo "Пользователь $NEW_USER добавлен в группу docker (перелогиньтесь, чтобы применилось)"
  fi
}

install_mysql() {
  if is_pkg_installed mysql-server; then
    echo "MySQL уже установлен, пропускаю"
  else
    echo "Установка MySQL Server..."
    apt install -y mysql-server
    echo "Рекомендуется выполнить: sudo mysql_secure_installation"
  fi
}

install_postgres() {
  if is_pkg_installed postgresql; then
    echo "PostgreSQL уже установлен, пропускаю"
  else
    echo "Установка PostgreSQL..."
    apt install -y postgresql postgresql-contrib
  fi
}

install_redis() {
  if is_pkg_installed redis-server; then
    echo "Redis уже установлен, пропускаю"
  else
    echo "Установка Redis..."
    apt install -y redis-server
  fi
}

install_nodejs() {
  if command -v node &>/dev/null; then
    echo "Node.js уже установлен ($(node -v)), пропускаю"
  else
    echo "Установка Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs
  fi
}

install_certbot() {
  if is_pkg_installed certbot; then
    echo "Certbot уже установлен, пропускаю"
  else
    echo "Установка Certbot (Let's Encrypt)..."
    apt install -y certbot python3-certbot-nginx
  fi
}

install_php() {
  if is_pkg_installed php-fpm; then
    echo "PHP-FPM уже установлен, пропускаю"
  else
    echo "Установка PHP-FPM..."
    apt install -y php-fpm php-mysql php-cli
  fi
}

install_git() {
  if command -v git &>/dev/null; then
    echo "Git уже установлен, пропускаю"
  else
    echo "Установка Git..."
    apt install -y git
  fi
}

if [[ -n "$SELECTED_PACKAGES" ]]; then
  for num in $SELECTED_PACKAGES; do
    case "$num" in
      1) install_nginx ;;
      2) install_docker ;;
      3) install_mysql ;;
      4) install_postgres ;;
      5) install_redis ;;
      6) install_nodejs ;;
      7) install_certbot ;;
      8) install_php ;;
      9) install_git ;;
      *) echo "Пропускаю неизвестный номер: $num" ;;
    esac
  done
else
  echo "Дополнительное ПО не выбрано, пропускаю"
fi

echo
echo "════════════════════════════════════════════════════════════"
echo " Готово! Всё выполнено за один запуск. Что сделано:"
echo "  • Система обновлена, включены автообновления безопасности"
echo "  • Пользователь: $NEW_USER (в группе sudo)"
echo "  • UFW: разрешены порты ${SSH_PORT}(SSH), ${ALLOWED_TCP_PORTS[*]}, всё остальное закрыто"
echo "  • fail2ban защищает SSH от перебора паролей"
echo "  • root по SSH отключён"
if [[ "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
  echo "  • Вход по паролю отключён — доступ только по SSH-ключу"
else
  echo "  • Вход по паролю пока разрешён"
fi
[[ -n "$SELECTED_PACKAGES" ]] && echo "  • Доп. ПО (установлено или уже было): $SELECTED_PACKAGES"
echo "════════════════════════════════════════════════════════════"
echo
echo "Скрипт можно запускать повторно (например, чтобы доустановить ещё пакеты) —"
echo "уже выполненные шаги будут автоматически пропущены."
echo
echo "ВАЖНО: прежде чем закрывать текущую SSH-сессию, откройте новое окно"
echo "и проверьте вход: ssh -p ${SSH_PORT} ${NEW_USER}@ВАШ_IP"
