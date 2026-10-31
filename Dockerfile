# LimeSurvey on Railway — wrapper around the maintained martialblog image.
#
# Why a wrapper at all (house style: bake constants, keep the deploy form
# zero-field, and survive Railway's root-owned volumes):
# - PORT: Railway injects PORT; the upstream image listens on LISTEN_PORT
#   (default 8080). entrypoint.sh maps PORT -> LISTEN_PORT at boot, the
#   same pattern as the GoToSocial template. Without this, Railway's
#   healthcheck would probe a port nothing listens on.
# - MPM: the upstream image ships with more than one MPM enabled and
#   Apache refuses to start (AH00534). entrypoint.sh removes every MPM
#   module and enables only prefork (required by mod_php) — the fix proven
#   by the existing Railway LimeSurvey template.
# - USER root: Railway mounts persistent volumes root-owned. The upstream
#   image runs as www-data, which would crash-loop on EACCES writing to
#   /data. The wrapper entrypoint runs as root, prepares /data (uploads +
#   security.php) owned by www-data, then execs the upstream entrypoint,
#   which runs the CLI auto-install (config.php generation + `console.php
#   install`) only when the database is not yet provisioned — idempotent
#   across restarts and redeploys.
# - PUBLIC_URL: derived at boot from the live RAILWAY_PUBLIC_DOMAIN, never
#   from a `https://${{RAILWAY_PUBLIC_DOMAIN}}` template variable. The
#   Spliit template proved such a variable can resolve to a bare `https://`
#   before the domain exists and break every page render; a set-but-broken
#   value is treated as unset here, exactly as in Spliit's entrypoint.
# - security.php: LimeSurvey generates this file on first boot and warns
#   it MUST be persistent (it holds the data-encryption keys). The wrapper
#   symlinks it into the /data volume before the upstream entrypoint runs,
#   so a restart never orphans encrypted survey data. config.php is
#   deliberately NOT symlinked: the upstream entrypoint regenerates it from
#   the current environment on every fresh container, so a rotated database
#   password can never be shadowed by a stale file.
# - Baked constants: DB_TYPE=pgsql, DB_PORT=5432, DB_NAME/DB_USERNAME=
#   limesurvey, ADMIN_NAME/ADMIN_EMAIL defaults. Railway's `templates
#   create` only carries ${{...}} expressions into template defaults, so
#   every literal lives here, not on the deploy form. The only template
#   variables are DB_HOST (${{postgres.RAILWAY_PRIVATE_DOMAIN}}),
#   DB_PASSWORD (${{postgres.POSTGRES_PASSWORD}}) and
#   ADMIN_PASSWORD (${{secret(32)}}), all single references.
# - No Docker HEALTHCHECK: the base image has no curl/wget guarantee for a
#   healthcheck binary; Railway's external healthcheckPath covers it.
#
# Upstream: LimeSurvey 7.8.0+261026 (GPL-2.0-or-later), image pinned by
# manifest digest (amd64+arm64), verified 2026-10-31. The image itself is
# built from the official LimeSurvey/LimeSurvey release tarball, checksum
# verified in the upstream Dockerfile.

FROM martialblog/limesurvey:7.8.0-261026-apache@sha256:c6d6e2bf0d824396fb09ca0297962b00326b8d1216a91889b13a0e040cb4b05f

USER root

# Baked constants (see header). DB_* host/password come from the template
# variables; everything else is fixed so the deploy form stays empty.
ENV DB_TYPE=pgsql \
    DB_PORT=5432 \
    DB_NAME=limesurvey \
    DB_USERNAME=limesurvey \
    DB_TABLE_PREFIX=lime_ \
    ADMIN_NAME="Railway Administrator" \
    ADMIN_EMAIL=admin@example.com \
    DEBUG=0

COPY entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/INAPP-Mobile/limesurvey"

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["apache2-foreground"]
