# AGENTS.md — Instructions for AI Coding Agents

## 1. Purpose

This repository implements Network Lab, a controlled Docker-based environment for researching network traffic, filtering, packet capture, and traffic classification.

This document defines mandatory instructions for AI agents and automated coding assistants working in this repository.

These instructions apply to code generation, editing, debugging, refactoring, documentation, and proposed operational commands.

When instructions conflict, prioritize:
1. User's explicit current request.
2. Safety and preservation of the host system and existing data.
3. The architecture and invariants in this document.
4. Existing implementation and project conventions.
5. General coding preferences.

Do not infer permission to make destructive changes merely because a task involves installation, deployment, or rebuilding.

## 2. Project architecture

The environment is intended to run on Ubuntu 24.04 using Rootless Docker under the dedicated account `dockerroot`.

The laboratory contains three containers:

| Container | Address | Network |
|---|---|---|
| `lab-client` | `10.231.10.3` | `lab-client-net` |
| `lab-filter` | `10.231.10.2`, `10.231.20.2` | Both laboratory networks |
| `lab-server` | `10.231.20.3` | `lab-server-net` |

The server provides a test HTTP service on TCP port 8080.

Expected networks:

- `lab-client-net`: `10.231.10.0/24`
- `lab-server-net`: `10.231.20.0/24`

The filter is the intended path between client and server.

Do not assume that topology alone enforces this path. Verify routing tables, IP forwarding, firewall rules, and actual packet captures when changing network configuration.

## 3. Rootless Docker requirements

- Docker daemon runs as `dockerroot`, not as host root.
- Administrative access to the daemon must use the existing Rootless Docker user session.
- Prefer `machinectl shell dockerroot@.host` for commands that require the user's systemd session or environment.
- Do not silently replace the established `machinectl` workflow with `sudo -iu` or another method.
- Compute the UID dynamically:

  ```bash
  DOCKER_UID="$(id -u dockerroot)"
  ```

- The expected Docker socket is:

  ```text
  /run/user/<dockerroot-uid>/docker.sock
  ```

- Set `DOCKER_HOST` explicitly when executing Docker commands in scripts:

  ```bash
  export DOCKER_HOST="unix:///run/user/$(id -u dockerroot)/docker.sock"
  ```

- Do not add ordinary laboratory users to a group that grants access to the Docker socket.
- Do not expose the Docker socket over TCP.
- Do not switch to rootful Docker without explicit user approval and a separate security review.
- Do not rerun `00-install-rootless-docker.sh` as part of ordinary setup or update operations.

Rootless Docker reduces risk but is not a complete security boundary against all host compromise.

## 4. Host protection invariants

The VPS may host an unrelated existing library and other services. Preservation of host data is mandatory.

Agents MUST NOT:

- Delete, move, recursively change ownership of, or recursively chmod unrelated host directories.
- Mount the existing library into any laboratory container.
- Expose host secrets, SSH private keys, credentials, or configuration files to containers.
- Grant laboratory users unrestricted sudo access on the host.
- Give laboratory users direct Docker socket access.
- Publish container ports to public host interfaces without explicit authorization.
- Disable the host firewall or AppArmor globally to make an experiment work.
- Replace existing system configuration files without checking for prior contents and making a backup when appropriate.
- Run destructive cleanup commands without identifying the exact target and confirming that relevant data is disposable.

Avoid broad operations such as `chmod -R 777`, `chown -R` on existing project roots, and indiscriminate Docker volume pruning.

Do not remove volumes, images, networks, or containers as an automatic troubleshooting step.

## 5. Repository responsibilities

Existing primary scripts:

- `00-install-rootless-docker.sh`: initial Rootless Docker installation.
- `setup.sh`: orchestration entry point.
- `10-configure-host.sh`: host-side laboratory configuration.
- `build-lab.sh`: container and network construction.
- `create-lab-users.sh`: participant account and SSH key management.

Supporting scripts may include:

- `labctl`
- `lab-ssh-gateway`
- `lab-index-captures.sh`
- `lab-prune-captures.py`

Some supporting files may be generated or installed by `10-configure-host.sh`. Verify the current repository before assuming their exact location or implementation.

Do not rewrite a working primary script merely to simplify another task. Prefer focused, minimal changes.

When modifying `setup.sh`, preserve the separation between initial host setup and container construction. The initial Rootless Docker installer must not be invoked automatically during every setup run.

## 6. Idempotency and safe configuration management

Host configuration scripts must be safe to rerun wherever practical.

Requirements:

- Use `set -Eeuo pipefail` in Bash scripts unless there is a documented reason not to.
- Use explicit quoting for paths and variable expansions.
- Check whether users, groups, directories, packages, services, and files already exist.
- Do not duplicate entries in shell initialization files or configuration lists.
- Do not overwrite SSH authorized keys when adding a new key.
- Do not reset participant passwords or credentials on repeated runs.
- Do not overwrite an existing Caddyfile without explicit authorization.
- Do not destroy existing PCAP files during deployment.
- Do not recreate containers when a restart or targeted update is sufficient.
- Validate generated sudoers files with `visudo -cf` before installation.
- Reload systemd after modifying unit files.
- Check service status after enabling or reloading a service.
- Back up existing configuration before replacing it, unless the operation is demonstrably a no-op.

If the existing state conflicts with the desired state, stop and report the conflict instead of silently overwriting it.

## 7. Participant access and SSH restrictions

The intended participant accounts are:

- `attacker`
- `defender`
- `ml-searcher`

Each participant uses an individual public SSH key. Participants may be created before their keys are available.

Rules:

- Never request, generate, or store a participant's private SSH key.
- Preserve all existing authorized keys when adding a key.
- Reject malformed public keys.
- Avoid duplicate authorized key entries.
- Restrict participant SSH sessions to the approved laboratory gateway.
- Do not enable arbitrary host shell commands or unrestricted SFTP merely for convenience.
- Do not grant participants general sudo privileges on the host.
- Validate SSH file ownership and permissions.
- Make the intended command allowlist explicit and test it.

The expected approved operations are status inspection and interactive shells in the three laboratory containers. Any additional operation requires explicit review.

The `attacker` role is limited to the authorized experimental environment. It does not authorize attacking external systems.

## 8. Container and network requirements

- Keep the client and server on separate internal Docker networks.
- Keep the filter connected to both networks.
- Do not attach the client directly to the server network.
- Do not publish ports unless explicitly required and reviewed.
- Do not mount the host's Docker socket into a container.
- Avoid unnecessary Linux capabilities.
- Add `NET_ADMIN` and `NET_RAW` only where required for the filter's function.
- Do not enable host networking as a shortcut.
- Keep container images and build definitions reproducible.
- Avoid embedding credentials in Dockerfiles or image layers.
- Verify actual network behavior with controlled test traffic and PCAP captures.

If a change alters network topology, include verification steps for both intended connectivity and unintended connectivity.

## 9. Shared workspace and capture storage

The shared workspace is intended to use the named Docker volume `lab-workspace` where supported by the current implementation.

The capture directory on the host is expected to be:

```text
/srv/network-lab/captures
```

Related directories may include:

```text
/srv/network-lab/workspace
/srv/network-lab/incoming
/srv/network-lab/metadata
/srv/network-lab/logs
```

Verify actual mounts and paths before modifying them.

All participants who have write access to the shared volume may be able to modify or delete each other's files. Never place secrets in the shared workspace.

The capture directory should not be writable by unrelated users or exposed as a general-purpose file server root.

## 10. Capture retention and quotas

The intended retention policy is:

- 14 days for stored captures.
- A logical target of 5 GiB total capture storage.
- Periodic cleanup via systemd timer.

Important distinction:

A script that checks file ages and total directory size implements a logical quota, not a hard filesystem quota. Disk usage may exceed the target between timer runs or when recent files cannot safely be removed.

When editing cleanup logic:

- Do not follow symbolic links.
- Do not delete files outside the capture root.
- Avoid deleting files that may still be actively written.
- Report files that cannot be removed.
- Preserve useful diagnostics.
- Never claim that a logical quota guarantees the disk cannot fill.
- Consider sidecar metadata files when defining cleanup policy.
- If hard storage limits are required, recommend a dedicated filesystem or supported disk quota mechanism.

Do not run destructive cleanup against real capture data as part of testing. Use a temporary test directory.

## 11. Metadata and packet analysis

The capture indexer may use `capinfos` to extract metadata from PCAP and PCAPNG files.

Expected outputs may include:

- capture start and end times;
- packet count;
- file size;
- capture format and link-layer information;
- hashes, if supported by the installed tool version.

Do not assume command-line flags are supported by every installed version of Wireshark/tshark utilities. Verify commands on the target OS and check exit status.

Metadata should not expose secrets or unrelated host information.

Caddy's static file browser is a file catalogue and download mechanism, not a browser-native packet-analysis tool.

## 12. Caddy and web access

Caddy is optional and may already be configured on the host.

Rules:

- Do not install or replace Caddy blindly if it is already present.
- Detect the actual service account before changing ACLs.
- Do not assume the account is always named `caddy`; inspect systemd configuration and process credentials.
- Do not make the entire laboratory root world-readable.
- Grant traversal only on required parent directories.
- Grant read access only to the intended capture directory.
- Do not expose the workspace, incoming directory, Docker data root, home directories, or host configuration through `file_server`.
- Do not expose credentials or password hashes in logs or generated documentation.
- Validate Caddy configuration before reload.
- Do not reload the service if validation fails.

Caddy syntax depends on its version. For Caddy 2.6.2, use `basicauth`; the `basic_auth` directive belongs to newer versions.

HTTPS and valid authentication are required before exposing the capture catalogue to participants over a public network.

Do not replace an existing Caddyfile merely to insert an example domain or placeholder password hash.

## 13. AppArmor and systemd

Do not disable AppArmor globally to make Rootless Docker work.

The Rootless Docker AppArmor profile is security-sensitive. In particular, `flags=(unconfined)` is an exception that weakens restrictions for the specified executable. Do not broaden it or describe it as a general security improvement.

When modifying systemd units:

- use absolute executable paths;
- define the intended service user and group;
- use least-privilege hardening where compatible;
- add write paths explicitly when using `ProtectSystem=strict`;
- reload systemd after changes;
- enable timers only after validating their service units;
- inspect service logs if a unit fails.

Never claim a timer is functioning based only on the existence of its unit file.

## 14. Coding standards

### Bash

- Prefer `set -Eeuo pipefail`.
- Quote variables unless deliberate word splitting is required.
- Use `$(...)` instead of legacy backticks.
- Never put spaces around `=` in assignments.
- Use `install -d` and `install` for explicit ownership and modes where appropriate.
- Avoid `eval`.
- Avoid parsing `ls` output.
- Use temporary files safely and clean them up with `trap`.
- Validate input before using it in commands.
- Use absolute paths for installed scripts.
- Keep output actionable and distinguish warnings from fatal errors.

### Python

- Use the standard library when practical for small host maintenance scripts.
- Handle filesystem errors explicitly.
- Avoid following symlinks when walking sensitive directories.
- Keep cleanup operations bounded to an explicit root.
- Report failures without silently swallowing all exceptions.
- Separate configuration constants from logic.

### Documentation

- Document destructive side effects.
- Include realistic commands and expected outcomes.
- Do not invent file paths, service names, or command-line options.
- Distinguish verified behavior from intended behavior.
- Keep README instructions consistent with the actual scripts.

## 15. Validation workflow

Before declaring a change complete, perform applicable checks:

1. Inspect the relevant existing files.
2. Confirm that the change preserves current architecture and paths.
3. For Bash scripts, run `bash -n`.
4. For Python scripts, run `python3 -m py_compile` using a temporary or disposable location when possible.
5. Validate generated sudoers files with `visudo -cf`.
6. Validate Caddy configuration with `caddy validate` when applicable.
7. Validate systemd units with `systemd-analyze verify`.
8. Check that generated files have the intended owner and permissions.
9. Check Docker networks, mounts, capabilities, and port bindings.
10. Verify that the Docker socket is absent from laboratory containers.
11. Test client-to-server traffic through the filter.
12. Verify that unintended external access is not introduced.
13. Confirm that existing capture files and unrelated host directories remain intact.

If a check cannot be run in the current environment, state that explicitly. Do not claim successful testing without evidence.

## 16. Changes requiring explicit user approval

Ask before:

- removing containers, images, networks, or volumes;
- deleting or bulk-modifying stored captures;
- replacing the Caddyfile;
- changing Rootless Docker to rootful Docker;
- changing subnet ranges or container IP addresses;
- exposing new ports to the Internet;
- granting new host privileges;
- altering the AppArmor security model;
- changing storage retention policy or deleting recent captures;
- modifying the existing library or unrelated host services.

A user request to implement a feature is not automatically authorization to destroy unrelated data.

## 17. Expected agent behavior

When asked to implement a change:

1. Identify the exact files involved.
2. Inspect existing implementation before editing.
3. Prefer a small, reviewable patch.
4. Preserve existing interfaces unless the user asks to change them.
5. Explain any assumptions that affect correctness or security.
6. Provide commands to validate the change.
7. State what was not tested.
8. Do not ask the user to resend files or context that are already available in the current workspace.
9. Do not regenerate unrelated scripts when the task concerns a single component.
10. Never claim a deployment or filesystem change occurred unless it was actually executed and verified.

The priority is a reproducible, isolated, maintainable laboratory that does not compromise the host or the user's existing data.
