#!/bin/bash
set -e
clear
# --- Read Domain and Admin Email from user ---
read -p "Enter your domain (IP/domain): " DOMAIN
read -p "Enter admin email: " ADMIN_EMAIL

# --- Variables ---
DB_NAME=panel
DB_USER=pterodactyl
DB_PASS=yourPassword

# --- Dependencies ---
apt update && apt install -y curl apt-transport-https ca-certificates gnupg unzip git tar sudo lsb-release software-properties-common cron

# --- Detect OS ---
OS=$(lsb_release -is | tr '[:upper:]' '[:lower:]')

if [[ "$OS" == "ubuntu" ]]; then
    echo "✅ Detected Ubuntu. Adding PPA for PHP..."
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
elif [[ "$OS" == "debian" ]]; then
    echo "✅ Detected Debian. Adding SURY PHP repo..."
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/sury-php.list
fi

# --- Add Redis repo ---
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list

apt update

# --- Install PHP and extensions, MariaDB, nginx, redis ---
apt install -y php8.3 php8.3-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} mariadb-server nginx redis-server

# --- Install Composer ---
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# --- Download Pterodactyl Panel ---
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage bootstrap/cache

# --- MariaDB Setup ---
mariadb -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
mariadb -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';"
mariadb -e "FLUSH PRIVILEGES;"

# --- Setup .env file ---
if [ ! -f ".env.example" ]; then
    curl -Lo .env.example https://raw.githubusercontent.com/pterodactyl/panel/develop/.env.example
fi
cp .env.example .env

sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env

# --- Clean old entries ---
sed -i '/^APP_ENVIRONMENT_ONLY=/d' .env
sed -i '/^APP_THEME=/d' .env
sed -i '/^APP_TIMEZONE=/d' .env
sed -i '/^MAIL_/d' .env

# --- Add new env variables ---
echo "APP_ENVIRONMENT_ONLY=false" >> .env
echo "APP_THEME=Nobita-hosting" >> .env

# --- Auto detect timezone ---
TIMEZONE=$(timedatectl show --property=Timezone --value)
echo "APP_TIMEZONE=${TIMEZONE}" >> .env

# --- Mail configuration ---
echo "MAIL_MAILER=smtp" >> .env
echo "MAIL_HOST=smtp.zoho.in" >> .env
echo "MAIL_PORT=587" >> .env
echo "MAIL_USERNAME=${ADMIN_EMAIL}" >> .env
echo "MAIL_PASSWORD=58@S5wZuWtpdDDX" >> .env
echo "MAIL_ENCRYPTION=tls" >> .env
echo "MAIL_FROM_ADDRESS=${ADMIN_EMAIL}" >> .env
echo 'MAIL_FROM_NAME="Nobita-hosting"' >> .env

# --- Install PHP dependencies ---
echo "✅ Installing PHP dependencies..."
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# --- Generate application key ---
echo "✅ Generating application key..."
php artisan key:generate --force

# --- Run migrations and seed ---
php artisan migrate --seed --force

# --- Permissions ---
chown -R www-data:www-data /var/www/pterodactyl
systemctl enable --now cron
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

# --- Nginx Setup ---
mkdir -p /etc/certs/panel
cd /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
-subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
-keyout privkey.pem -out fullchain.pem

cat > /etc/nginx/sites-available/pterodactyl.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }

    sub_filter '</body>' '<footer style="text-align: center; padding: 10px; margin-top: 20px; font-size: 12px; color: #666;">Powered by Nobita</footer></body>';
    sub_filter_once on;
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx

# --- Setup Redis and Queue Worker ---
cat > /etc/systemd/system/pteroq.service << 'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now redis-server
systemctl enable --now pteroq.service

clear

# --- Auto create admin user ---
echo -e "\n\e[1;33mCreating admin user automatically...\e[0m"
php artisan p:user:make --admin --email="${ADMIN_EMAIL}" --username="admin" --name="Administrator" --password="admin123" --no-interaction

# --- Final Info Display with colors and Check Email message ---
echo -e "\n\e[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
echo -e "\e[1;36m  ✅ Installation Completed Successfully! \e[0m"
echo -e "\e[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
echo -e "\e[1;34m  🌐 Your Panel URL: \e[1;37mhttps://${DOMAIN}\e[0m"
echo -e "\e[1;34m  📂 Panel Directory: \e[1;37m/var/www/pterodactyl\e[0m"
echo -e "\e[1;34m  👤 Admin User: \e[1;37madmin\e[0m"
echo -e "\e[1;34m  🔑 Admin Password: \e[1;37madmin123\e[0m"
echo -e "\e[1;34m  📧 Admin Email: \e[1;37m${ADMIN_EMAIL}\e[0m"
echo -e "\e[1;34m  🔑 DB User: \e[1;37m${DB_USER}\e[0m"
echo -e "\e[1;34m  🔑 DB Password: \e[1;37m${DB_PASS}\e[0m"
echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
echo -e "\e[1;35m  🎉 Powered by Nobita! \e[0m"
echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
echo -e "\e[1;31m  📧 Please check your email (${ADMIN_EMAIL}) for important notifications!\e[0m"
echo -e "\n"
