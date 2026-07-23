# Deploying this fork to Azure Container Apps

This fork is deployed as a container on Azure Container Apps (ACA) behind a
private network, alongside the Ekonet CMS. Infra: `FXinnovation/ekonet-infra`
(`ca-tolgee`). This doc covers building the image and the runtime config.

## Build the image (into the private ACR)

The root [`Dockerfile`](../Dockerfile) is self-contained (Gradle + webapp build
happen inside it), so no JDK/Node toolchain is needed on the build host. From
an in-VNet CI runner:

```bash
az acr build \
  --registry crekonetdevcc \
  --agent-pool ekonetbuilds \
  --image tolgee:<tag> \
  .
```

This mirrors the release pipeline (`./gradlew bootJar dockerPrepare` → docker
build of `build/docker`) in a single build.

## Runtime configuration (env vars)

Set on the container app. Spring relaxed binding maps `A_B_C` → `a.b.c`.
Terraform wires the datasource + a KV-backed password; the rest are app config.

| Env var | Purpose |
|---|---|
| `SPRING_DATASOURCE_URL` | `jdbc:postgresql://<pg-host>:5432/tolgee` (external Azure Postgres) |
| `SPRING_DATASOURCE_USERNAME` | Postgres user |
| `SPRING_DATASOURCE_PASSWORD` | from Key Vault (`postgres-admin-password`) |
| `TOLGEE_POSTGRES_AUTOSTART_ENABLED` | **`false`** — do not start the image's embedded Postgres |
| `TOLGEE_AUTHENTICATION_JWT_SECRET` | ≥ 64-char secret (Key Vault) |
| `TOLGEE_AUTHENTICATION_INITIAL_USERNAME` | first admin user |
| `TOLGEE_AUTHENTICATION_INITIAL_PASSWORD` | first admin password (Key Vault; rotate after first login) |
| `TOLGEE_FRONTEND_URL` | public hostname, e.g. `https://tolgee.ateko.com` |

> **Why external Postgres:** the image bundles Postgres for a single-container
> quickstart (data in the `/data` volume). On ACA we use the shared Azure
> Postgres Flexible server instead — hence `TOLGEE_POSTGRES_AUTOSTART_ENABLED=false`.

## Health

The container exposes `GET /actuator/health` (already used by the image's
`HEALTHCHECK`); use it for ACA probes.

## Follow-ups

- **File storage.** Uploaded screenshots default to the local `/data` volume,
  which does not survive scale-to-zero / revision changes on ACA. Configure
  S3-compatible storage (`tolgee.file-storage.s3.*`) against Azure Blob, or
  accept ephemeral screenshots. Track before enabling scale-to-zero for Tolgee.
- **SSO.** Optionally wire Entra/OAuth2 so translators sign in with corporate
  identities instead of native Tolgee accounts.
