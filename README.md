# Redis Cluster Lifecycle Tool

A complete Ansible-driven CLI tool for managing a 6-node Redis cluster with zero-downtime rolling upgrades.

## Project Structure
```
submission/
├── redis-tool             ← Python CLI entrypoint
├── ansible/
│   ├── ansible.cfg        ← Ansible configuration
│   ├── inventory/
│   │   └── hosts.ini      ← 6 Redis nodes with static IPs
│   ├── playbooks/
│   │   ├── provision.yml  ← Installs Redis, creates cluster
│   │   ├── status.yml     ← Fetches node and cluster state
│   │   └── upgrade_node.yml ← Idempotent upgrade task for a single node
│   └── roles/
│       └── redis/         ← Core role (download, compile, config, systemd)
├── infra/
│   ├── Containerfile      ← Ubuntu 22.04 base image with SSH
│   └── compose.yml        ← Docker/Podman compose network
└── README.md
```

## How to bring up the container infrastructure
The tool is designed to work seamlessly with either Docker or Podman. The network is configured statically on the `10.99.0.0/24` subnet.

1. Navigate to the `infra` directory:
   ```bash
   cd infra
   ```
2. Bring up the 6 container nodes:
   ```bash
   docker compose up -d
   # OR, if using podman:
   podman-compose up -d
   ```
   *(Note: The containers will map SSH port 22 to host ports 2201-2206, though Ansible connects locally via `127.0.0.1` and uses the static container IPs `10.99.0.11` to `10.99.0.16` directly over the bridge network for internal commands.)*

## How to run each `redis-tool` command

The `redis-tool` acts as an orchestration wrapper around Ansible and direct TCP commands. It automatically detects the container runtime and Ansible version before running any commands.

**Phase 1: Provision the Cluster**
```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
```

**Phase 2: Seed Data and Verify**
```bash
./redis-tool data seed --keys 1000
./redis-tool data verify --keys 1000
```

**Phase 3: Cluster Status**
```bash
./redis-tool status
```

**Phase 4: Rolling Upgrade**
```bash
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
```

**Phase 5: Full Verification**
```bash
./redis-tool verify --full
```

## Rolling Upgrade Strategy

To ensure zero client-visible downtime and guaranteed data integrity, the tool implements the following sequence:

1. **Pre-flight Checks**: Verifies that the cluster is healthy, all nodes are reachable, and the cluster state is currently `ok`.
2. **Upgrade Replicas First**: We iterate over the replicas sequentially. Upgrading replicas is entirely safe since they do not serve client writes. We stop Redis, replace the binary with the target version, and restart it. We wait for it to resync with its master.
3. **Upgrade Masters via Failover**: Once all replicas are upgraded, we cannot simply take down a master, or the cluster would experience a brief write outage. Instead, we:
   - Issue a `CLUSTER FAILOVER` command to the replica of the target master.
   - The cluster safely promotes the upgraded replica to be the new master, with zero data loss.
   - The old master gracefully downgrades to a replica state.
   - We then safely upgrade the old master (which is now a replica).
4. **Post-upgrade Verification**: The tool checks the cluster state, topological integrity, and the Redis versions to confirm all nodes are successfully on `7.2.6`.

**Why this strategy?**
This strategy completely eliminates write interruption. The Redis `CLUSTER FAILOVER` mechanism coordinates the pause in writes natively between the master and replica, ensuring zero lost bytes, whereas letting the cluster auto-failover by aggressively killing the master could result in a dropped packet or brief connection error for clients.

## Assumptions & Trade-offs
- **SSH Auth**: The inventory strictly uses SSH key-based authentication (`id_rsa` generated in `infra/`) to securely connect without passwords, meeting the production requirements.
- **Python-driven Orchestration**: Instead of one monolithic Ansible playbook for the upgrade, `redis-tool` loops over the nodes in Python and calls a smaller `upgrade_node.yml` playbook. This makes orchestrating the complex failover logic vastly easier to read, test, and abort upon failure compared to Jinja/Ansible loop logic.
- **Data Operations**: `data seed` and `data verify` are executed via `ansible redis-node-1 -m shell` looping over `redis-cli`, meaning they are securely orchestrated to execute directly inside the cluster container to bypass any host-networking isolation issues in Podman.

## Known Limitations
- The script currently assumes `redis-cli` is accessible via `ansible localhost shell` if used locally, or it can be easily run natively inside the container.
- Rollback mechanism (Stretch Goal S3) is not fully implemented in the parser.
- The `redis-tool` makes hardcoded assumptions about the internal IP addresses (`10.99.0.11` to `10.99.0.16`), which is adequate for this specific 6-node static test but would need to parse `hosts.ini` dynamically in a production version.
