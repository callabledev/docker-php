#!/bin/sh
set -eu
version="${CHAINGUARD_PHP_PACKAGE_VERSION}"

for extension in redis raphf http; do
    cd "/build/$extension"
    phpize
    bash ./configure --with-php-config=/usr/bin/php-config
    make -j2
    make install
    printf 'extension=%s.so\n' "$extension" > "/etc/php/conf.d/40-$extension.ini"
done
# HTTP requires raphf to be loaded first.
mv /etc/php/conf.d/40-http.ini /etc/php/conf.d/50-http.ini
php -m

runtime=/out/opt/chainguard
extensions=/out/usr/local/lib/php/extensions/no-debug-non-zts-20230831
mkdir -p "$runtime" "$extensions" /out/usr/local/bin /out/usr/local/sbin /out/usr/local/etc/php/conf.d

# Include the ELF dependency closure, rather than the development environment.
lddtree -l /usr/bin/php /usr/bin/php-fpm /usr/lib/php/modules/*.so > /tmp/runtime-files.unsorted
sort -u /tmp/runtime-files.unsorted > /tmp/runtime-files
while IFS= read -r file; do
    case "$file" in
        /usr/bin/php|/usr/bin/php-fpm|/usr/lib/php/modules/*) ;;
        /*) cp --parents -L "$file" "$runtime/" ;;
    esac
done < /tmp/runtime-files
mkdir -p "$runtime/usr/lib"
cp -L /usr/lib/ld-linux-x86-64.so.2 /usr/lib/libnss_dns.so.2 /usr/lib/libnss_files.so.2 "$runtime/usr/lib/"
cp /usr/bin/php /out/usr/local/bin/php
cp /usr/bin/php-fpm /out/usr/local/sbin/php-fpm
cp /usr/lib/php/modules/*.so "$extensions/"
cp /etc/php/conf.d/*.ini /out/usr/local/etc/php/conf.d/
printf 'extension_dir=/usr/local/lib/php/extensions/no-debug-non-zts-20230831\n' \
    > /out/usr/local/etc/php/conf.d/00-chainguard-runtime.ini

# Both PHP_BINARY and direct FPM execution must use the private ELF loader.
for binary in /out/usr/local/bin/php /out/usr/local/sbin/php-fpm; do
    patchelf --set-interpreter /opt/chainguard/usr/lib/ld-linux-x86-64.so.2 \
        --force-rpath --set-rpath /opt/chainguard/usr/lib "$binary"
done
mkdir -p /out/usr/share/chainguard-php
cp /usr/lib/apk/db/installed /out/usr/share/chainguard-php/packages.txt
sha256sum /usr/bin/php /usr/bin/php-fpm > /out/usr/share/chainguard-php/source-binaries.sha256
printf '%s\n' "$version" > /out/usr/share/chainguard-php/package-version
