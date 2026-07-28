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
# Gradle's node plugin downloads its own Node to build the webapp, so only a
# JDK is required here.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk AS build

WORKDIR /src
COPY . .

# bootJar builds backend + webapp; dockerPrepare assembles build/docker with
# BOOT-INF/{lib,classes}, META-INF, cmd.sh and the .VERSION file.
# (No --mount=type=cache here — ACR Tasks' quick-build engine doesn't run with
# BuildKit, which that flag requires. Costs Gradle-cache reuse between builds,
# not correctness.)
RUN ./gradlew --no-daemon bootJar dockerPrepare

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
COPY --from=build --chmod=755 /src/build/docker/cmd.sh /app/cmd.sh

ENTRYPOINT ["/app/cmd.sh"]

HEALTHCHECK --interval=10s --timeout=3s --retries=20 \
    CMD wget --spider -q "http://127.0.0.1:$HEALTHCHECK_PORT/actuator/health" || exit 1
