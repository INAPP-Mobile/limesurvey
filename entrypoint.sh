#!/bin/bash
# LimeSurvey wrapper entrypoint for Railway — see Dockerfile header.
set -e

# 1. Railway's injected PORT -> the upstream image's LISTEN_PORT.
export LISTEN_PORT="${PORT:-8080}"
echo "[entrypoint] listening on port ${LISTEN_PORT}."

# 2. Public URL: derive from the live Railway domain. A set-but-broken
# value (empty, bare scheme, or an unresolved ${{...}} expression — the
# Spliit failure mode) is treated as unset so the app derives it from the
# request instead of rendering broken links.
case "${PUBLIC_URL:-}" in
  ""|"http://"|"https://"|*'${{'*)
    if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
      export PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
      echo "[entrypoint] PUBLIC_URL derived: ${PUBLIC_URL}."
    else
      unset PUBLIC_URL
      echo "[entrypoint] PUBLIC_URL unset and no public domain; app default applies."
    fi
    ;;
  *)
    echo "[entrypoint] PUBLIC_URL kept as set."
    ;;
esac

# 3a. Apache MPM fix (proven by the incumbent Railway template): the
# upstream image ships with more than one MPM enabled (Debian Trixie's
# mpm_event plus php's mpm_prefork), and Apache refuses to start with
# "AH00534: More than one MPM loaded". Remove every MPM module and enable
# only prefork, which mod_php requires.
rm -f /etc/apache2/mods-enabled/mpm_event.load /etc/apache2/mods-enabled/mpm_event.conf
rm -f /etc/apache2/mods-enabled/mpm_worker.load /etc/apache2/mods-enabled/mpm_worker.conf
rm -f /etc/apache2/mods-enabled/mpm_prefork.load /etc/apache2/mods-enabled/mpm_prefork.conf
a2enmod mpm_prefork >/dev/null
echo "[entrypoint] Apache MPM fixed to prefork."

# 3. Persistent volume (/data, mounted by Railway, root-owned on arrival).
# Uploads and the generated security.php must survive restarts; everything
# else (config.php, Yii runtime caches) is regenerated from the environment.
mkdir -p /data/upload
chown www-data:www-data /data /data/upload

# Uploads: symlink the webroot upload dir into the volume, seeding it with
# the image's shipped upload content on first boot so no default file is lost.
if [ ! -L /var/www/html/upload ]; then
  if [ -z "$(ls -A /data/upload 2>/dev/null)" ] && [ -d /var/www/html/upload ]; then
    cp -a /var/www/html/upload/. /data/upload/ 2>/dev/null || true
  fi
  rm -rf /var/www/html/upload
  ln -s /data/upload /var/www/html/upload
  echo "[entrypoint] upload dir -> /data/upload."
fi

# Theme seed (incumbent-template lesson): the app expects the survey
# themes under upload/themes/survey, but the image ships them under
# themes/survey. Copy them into the volume once so theme rendering never
# 404s after the volume hides the image's packaged upload content.
if [ ! -e /data/upload/themes/survey/vanilla ] && [ -d /var/www/html/themes/survey ]; then
  mkdir -p /data/upload/themes
  cp -a /var/www/html/themes/survey /data/upload/themes/survey
  chown -R www-data:www-data /data/upload/themes
  echo "[entrypoint] survey themes seeded into /data/upload/themes."
fi

# security.php: LimeSurvey generates this on first boot and it MUST persist
# (data-encryption keys). Symlink it into the volume BEFORE the upstream
# entrypoint runs: on first boot the target does not exist, so upstream's
# `-f` check fails and it writes through the symlink into /data; on later
# boots the target exists and upstream keeps it untouched.
if [ ! -L /var/www/html/application/config/security.php ]; then
  ln -s /data/security.php /var/www/html/application/config/security.php
  echo "[entrypoint] security.php -> /data/security.php."
fi

# 4. Chain into the upstream entrypoint: it waits for the database,
# generates config.php from the environment, runs `console.php updatedb`
# and installs (creating the admin account) only if the database is not
# yet provisioned, then execs apache2-foreground.
echo "[entrypoint] starting LimeSurvey (upstream entrypoint)..."
exec /usr/local/bin/entrypoint.sh "$@"
