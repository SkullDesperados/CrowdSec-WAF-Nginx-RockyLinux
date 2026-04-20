#!/bin/bash
set -e

# --- STABLE VERSIONS CONFIGURATION ---
VER_NGINX=$(nginx -v 2>&1 | cut -d '/' -f2)
VER_LUAJIT="v2.1-20250826"
VER_NDK="v0.3.3"
VER_LUA_MOD="v0.10.27"
VER_CJSON="2.1.0.13"
VER_RESTY_CORE="v0.1.30"
VER_RESTY_LRU="v0.15"
VER_RESTY_HTTP="v0.17.2"
VER_RESTY_STR="v0.11"
VER_RESTY_SSL="1.7.1"
VER_CS_BOUNCER="v1.1.5"

# --- FORCE REINSTALL CHECK ---
FORCE_REINSTALL=false
if [[ "$1" == "--force" ]]; then
    FORCE_REINSTALL=true
    echo "Force mode enabled: Overwriting existing directories."
fi

# --- DOWNLOAD VERIFICATION FUNCTION ---
confirm_download() {
    local dir=$1
    if [ -d "$dir" ]; then
        if [ "$FORCE_REINSTALL" = true ]; then
            rm -rf "$dir"
            return 0
        fi
        echo -e "\nWarning: Directory '$dir' already exists."
        read -p "Do you want to delete it to re-download fresh? (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            rm -rf "$dir"
            return 0
        else
            echo "Skipping download for $dir."
            return 1
        fi
    fi
    return 0
}
# Clean
rm -f /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf

# Install system dependencies
echo "-> Installing system dependencies"
dnf install -y gettext lua-devel pcre-devel dpkg git wget make gcc openssl-devel

mkdir -p /opt/nginx/nginx_extension/
cd /opt/nginx/nginx_extension/

# --- LUAJIT INSTALLATION ---
if confirm_download "luajit2"; then
    git clone --depth 1 --branch $VER_LUAJIT https://github.com/openresty/luajit2.git
fi
echo "-> Compiling LuaJIT"
cd luajit2 && make -j"$(nproc)" && make install PREFIX=/opt/nginx/luajit
cd ..

# --- NGINX MODULES PREPARATION ---
if confirm_download "ngx_devel_kit"; then
    git clone --depth 1 --branch $VER_NDK https://github.com/simplresty/ngx_devel_kit.git
fi

if confirm_download "lua-nginx-module"; then
    git clone --depth 1 --branch $VER_LUA_MOD https://github.com/openresty/lua-nginx-module.git
fi

# --- NGINX COMPILATION ---
echo "-> Configuring and Compiling Nginx $VER_NGINX"
export LUAJIT_LIB=/opt/nginx/luajit/lib
export LUAJIT_INC=/opt/nginx/luajit/include/luajit-2.1

# Ensure Nginx source directory exists before proceeding
if [ ! -d "/opt/nginx/nginx-$VER_NGINX" ]; then
    echo "Error: Directory /opt/nginx/nginx-$VER_NGINX not found."
    exit 1
fi

cd /opt/nginx/nginx-$VER_NGINX/
./configure \
  --with-compat \
  --prefix=/opt/nginx \
  --with-http_ssl_module \
  --with-ld-opt="-Wl,-rpath,/opt/nginx/luajit/lib" \
  --add-dynamic-module=/opt/nginx/nginx_extension/ngx_devel_kit \
  --add-dynamic-module=/opt/nginx/nginx_extension/lua-nginx-module

make -j"$(nproc)"
make install
mkdir -p /etc/nginx/modules/
cp objs/*.so /etc/nginx/modules/

# --- LUA LIBRARIES (CJSON & RESTY) ---
echo "-> Installing Lua libraries"
cd /opt/nginx/nginx_extension
if confirm_download "lua-cjson"; then
    git clone --depth 1 --branch $VER_CJSON https://github.com/openresty/lua-cjson.git
fi
cd lua-cjson && make LUA_INCLUDE_DIR=/opt/nginx/luajit/include/luajit-2.1
mkdir -p /opt/nginx/lualib/resty
cp cjson.so /opt/nginx/lualib/

libs=(
    "openresty/lua-resty-core:$VER_RESTY_CORE"
    "openresty/lua-resty-lrucache:$VER_RESTY_LRU"
    "openresty/lua-resty-string:$VER_RESTY_STR"
    "ledgetech/lua-resty-http:$VER_RESTY_HTTP"
    "fffonion/lua-resty-openssl:$VER_RESTY_SSL"
)

for entry in "${libs[@]}"; do
    repo=${entry%%:*}; tag=${entry#*:}; name=$(basename $repo)
    cd /opt/nginx/nginx_extension
    if confirm_download "$name"; then git clone --depth 1 --branch $tag https://github.com/$repo.git; fi
    cp -r $name/lib/resty/* /opt/nginx/lualib/resty/
done

# --- CROWDSEC SETUP ---
echo "-> Finalizing CrowdSec setup"
mkdir -p /opt/crowdsec
cd /opt/crowdsec

if confirm_download "cs-nginx-bouncer-installer"; then
    wget -O cs-nginx-bouncer.tar.gz https://github.com/crowdsecurity/cs-nginx-bouncer/archive/refs/tags/$VER_CS_BOUNCER.tar.gz
    tar xvzf cs-nginx-bouncer.tar.gz

    # Identify the extracted folder (e.g., cs-nginx-bouncer-1.1.5)
    EXTRACTED_DIR=$(ls -d cs-nginx-bouncer-*/ | head -n 1)

    # Rename it cleanly to our target name
    mv "$EXTRACTED_DIR" cs-nginx-bouncer-installer
    rm -f cs-nginx-bouncer.tar.gz
fi

cd cs-nginx-bouncer-installer
if confirm_download "lua-mod"; then
    git clone --depth 1 https://github.com/crowdsecurity/lua-cs-bouncer.git lua-mod
fi

# Copy specific bouncer files to Nginx library path
cp lua-mod/lib/crowdsec.lua /opt/nginx/lualib/
cp -r lua-mod/lib/plugins /opt/nginx/lualib/

# Execute the official installer
./install.sh -y

# --- PERMISSIONS SETUP ---
chown -R root:root /opt/nginx/lualib/
chmod -R 755 /opt/nginx/lualib/

echo -e "\nInstallation completed successfully."

echo "Reminder: Add the following paths to your nginx.conf:"

