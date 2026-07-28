# Self-contained multi-stage build for the Ateko Tolgee fork.
#
# Purpose: build the fork (which carries our security fixes) into an image
# WITHOUT needing a JDK/Gradle/Node toolchain on the build host — everything
# happens inside the build stage. This lets our private-network CI build it
# with a single command from the repo root:
#
#   az acr build --registry crekonetdevcc --agent-pool ekonetbuilds \
#     --image tolgee:<tag> .
#
# The two stages mirror the project's own release pipeline
# (`./gradlew bootJar dockerPrepare`, then a docker build of build/docker —
# see gradle/docker.gradle and docker/app/Dockerfile), collapsed into one
# Dockerfile. See docs/DEPLOY-ACA.md for the runtime configuration.

# ---------------------------------------------------------------------------
# Stage 1 — build the Spring Boot jar and stage the docker context.
# gradle/webapp.gradle's installWebappDeps/buildWebapp tasks shell out to a
# system `npm` directly (no Gradle-managed Node download), so Node must be
# installed here. Version matches the project's own CI (actions/setup-node
# node-version: "22.x" in .github/workflows).
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk AS build

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# `az acr build` excludes .git from the uploaded source by default. Two
# things in the webapp's install chain need a real git repo:
#   - husky/bin.mjs (package.json's init-husky script) errors without one —
#     HUSKY=0 is Husky's own documented env var to skip it cleanly.
#   - webapp/scripts/updateBranchInfo.mjs runs `git rev-parse --abbrev-ref
#     HEAD` directly, with no fallback — give it a minimal repo to satisfy
#     that (the branch name it records is purely informational).
ENV HUSKY=0
RUN git init -q \
    && git -c user.email=build@ekonet.local -c user.name=build commit -q --allow-empty -m "docker build"

# bootJar builds backend + webapp; dockerPrepare assembles build/docker with
# BOOT-INF/{lib,classes}, META-INF, cmd.sh and the .VERSION file.
# (No --mount=type=cache here — ACR Tasks' quick-build engine doesn't run with
# BuildKit, which that flag requires. Costs Gradle-cache reuse between builds,
# not correctness.)
#
# gradle.properties requests -Xmx6g for BOTH the Gradle daemon and the
# separate Kotlin compiler daemon (kotlin.daemon.jvm.options) — up to 12 GiB
# combined, tuned for a bigger CI host than our build agent. Override both
# down to fit our agent pool (S2 = 8 GiB) with headroom, rather than editing
# the project's own upstream build tuning.
RUN ./gradlew --no-daemon bootJar dockerPrepare \
    -Dorg.gradle.jvmargs="-Xmx3g" \
    -Dkotlin.daemon.jvm.options="-Xmx3g"

# ---------------------------------------------------------------------------
# Stage 2 — runtime image. Kept identical to docker/app/Dockerfile: a JDK on
# the Postgres base so Tolgee's optional embedded Postgres still works. In ACA
# we disable it (TOLGEE_POSTGRES_AUTOSTART_ENABLED=false) and point at external
# Azure Postgres.
# ---------------------------------------------------------------------------
FROM postgres:13.20-alpine3.21

ENTRYPOINT []

RUN apk --no-cache add openjdk21
RUN apk --no-cache add "libxml2>=2.13.4-r5"

EXPOSE 8080
VOLUME /data

ENV HEALTHCHECK_PORT=8080 \
    spring_profiles_active=docker

COPY --from=build /src/build/docker/BOOT-INF/lib /app/lib
COPY --from=build /src/build/docker/META-INF /app/META-INF
COPY --from=build /src/build/docker/BOOT-INF/classes /app
COPY --from=build /src/build/docker/cmd.sh /app/cmd.sh
RUN chmod 755 /app/cmd.sh

ENTRYPOINT ["/app/cmd.sh"]

HEALTHCHECK --interval=10s --timeout=3s --retries=20 \
    CMD wget --spider -q "http://127.0.0.1:$HEALTHCHECK_PORT/actuator/health" || exit 1
