# Security station image. Every tool is pinned, and the trivy binary and its two
# databases are baked in together as one set, because they are a version pair:
# trivy hard-fails when the local DB schema is older than the CLI expects, and
# --skip-db-update does not rescue it.
FROM debian:trixie-slim

ARG GITLEAKS_VERSION=8.30.1
ARG TRIVY_VERSION=0.74.0
ARG OPENGREP_VERSION=1.30.0
# Opengrep rules have no version of their own. Pin the source commit and record
# a digest of the directory, so a verdict can be tied to the rules that produced it.
#
# opengrep/opengrep-rules was archived on 2025-11-28 and is frozen. That is not a
# reason to move to semgrep/semgrep-rules: on 2024-12-13, the day Opengrep forked
# it, Semgrep relicensed that repository from LGPL-2.1 + Commons Clause to the
# Semgrep Rules License v1.0, which permits internal use only and forbids
# redistribution. This station image is built to be carried into a customer
# network, so it must carry rules it is allowed to redistribute. The fork is the
# last such snapshot, which makes this pin the end of the line rather than a
# version we are behind on. Rule freshness is a stated limitation of the SAST
# layer; gitleaks and trivy keep their own updatable data.
ARG OPENGREP_RULES_COMMIT=f1d2b562b414783763fd02a6ed2736eaed622efa

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/gitleaks.tgz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
 && tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks \
 && rm /tmp/gitleaks.tgz \
 && gitleaks version

RUN curl -fsSL -o /tmp/trivy.tgz \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
 && tar -xzf /tmp/trivy.tgz -C /usr/local/bin trivy \
 && rm /tmp/trivy.tgz \
 && trivy --version

RUN curl -fsSL -o /usr/local/bin/opengrep \
      "https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/opengrep_manylinux_x86" \
 && chmod 0755 /usr/local/bin/opengrep \
 && opengrep --version

# Rules and databases, copied in at build time. Inside the customer network this
# image is what crosses the airlock; nothing fetches rules at scan time.
#
# The rules repository is pruned down to its language directories. Everything
# else at the top level is project scaffolding, and opengrep reads any .yaml it
# finds under --config as a rule: .pre-commit-config.yaml and .github/stale.yml
# both abort the whole scan with "invalid configuration file found". The repo
# also ships its own .semgrepignore, which has no business on this station.
RUN git clone --quiet https://github.com/opengrep/opengrep-rules /opt/airlock/rules \
 && git -C /opt/airlock/rules checkout --quiet "${OPENGREP_RULES_COMMIT}" \
 && cp /opt/airlock/rules/LICENSE /opt/airlock/opengrep-rules-LICENSE \
 && rm -rf /opt/airlock/rules/.git /opt/airlock/rules/scripts /opt/airlock/rules/stats \
 && find /opt/airlock/rules -maxdepth 1 -mindepth 1 \( -type f -o -name '.*' \) -exec rm -rf {} + \
 && tar --sort=name --mtime='1970-01-01' --owner=0 --group=0 --numeric-owner \
        -cf - -C /opt/airlock rules \
    | sha256sum | awk '{print $1}' > /opt/airlock/rules.sha256 \
 && echo "${OPENGREP_RULES_COMMIT}" > /opt/airlock/rules.commit

ENV TRIVY_CACHE_DIR=/opt/airlock/trivy-cache
RUN trivy image --download-db-only --cache-dir "${TRIVY_CACHE_DIR}" \
 && trivy image --download-java-db-only --cache-dir "${TRIVY_CACHE_DIR}"

COPY gitleaks.toml /opt/airlock/gitleaks.toml

# Scripts are bind-mounted over this in compose so they can be edited without a rebuild.
RUN mkdir -p /opt/airlock/scripts
ENV PATH=/opt/airlock/scripts:$PATH
ENV AIRLOCK_HOME=/opt/airlock

WORKDIR /transfer
