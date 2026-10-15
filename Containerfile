# mcl-spartan
#
# The Spartan Mind: hears the real wire, reasons once about one story, and posts
# what it made of it to the square.
#
# ONE SMALL FILE PERSISTS: the mind's daily token ledger (mind_budget), which is
# what makes the cap survive a restart. deploy/docker-compose.yml mounts a host
# directory at MCL_DATA_DIR for it.

# ⚠ THE TEAM IMAGE PAIR, PINNED BY DATED TAG AND DIGEST. macula-ci-otp is
# macula-io/macula-ci-images' build image: OTP 28.4.3 on Debian trixie with an
# OpenSSL carrying ML-DSA, rebar3 3.27.0 and Rust, all pinned. The release runs
# on macula-pq-runtime of the same date, the same Debian, so its ERTS and NIFs
# match the runtime's glibc. 20260923-1444 is the pair the rocksdb images are
# derived from, so every mcl service sits on one base. lint.yml pins the same
# build image, and the service tests guard all three pins.
FROM ghcr.io/macula-io/macula-ci-otp:20260923-1444@sha256:dd2ba6eb858a0eacedf0179300323fe5c6da46fb308d22da0ca8cfcd1f0718dc AS builder

# ⚠ THE OTP RELEASE, ASSERTED HERE because the image tag names a date, not a
# release. The same check as lint.yml's toolchain step.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime:20260923-1444@sha256:15a5501b7277804c5a62c93121d157773d1401d238a1bf630ef4b50fc2f1df09
# LINKS THE PACKAGE TO THE REPOSITORY. A package without this label is an orphan
# on registries that read it: it does not appear on the repository page and does
# not inherit its visibility.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-spartan"
# THIS image's commit (build-push passes github.sha).
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# The runtime image carries what the release loads: OpenSSL 3.5, zlib, libstdc++,
# libtinfo, CA certificates (the endpoint is called over verified TLS), and curl
# for the healthcheck below.
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_spartan ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_spartan
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_spartan

# The mind's daily ledger. Small, and it must outlive the container: a ledger
# that starts fresh every recreate is not a cap. Mounted in the compose file.
ENV MCL_DATA_DIR=/data
VOLUME ["/data"]

# The node identity key: what makes every post attributable to this mind.
VOLUME ["/etc/mcl/secrets"]

# /health is served on a Unix socket only (mcl_om health_socket); mcl_om creates
# the socket, mode 0600, in this directory.
RUN mkdir -p /run/mcl
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS --unix-socket /run/mcl/health.sock http://localhost/health || exit 1

CMD ["/app/bin/mcl_spartan", "foreground"]
