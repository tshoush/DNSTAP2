# Installing the `dnstap2` collector on Red Hat Enterprise Linux 7.9 (Docker)

This guide builds and runs the containerized `dnstap2` **debug collector** on
RHEL 7.9 using `docker/Dockerfile.rhel7.9`. For the native (no-Docker)
production install on RHEL, use the standalone installers in `../scripts/`
(`install_dnstap_receiver.sh`, `install_dnscollector_receiver.sh`, etc.) — see
`../QUICKSTART.md`.

> **Scope.** The image packages only the Phase-1 `dnstap2` Python debug
> collector, not the production Vector / DNS-collector data plane (`../CLAUDE.md`).

## Why RHEL 7.9 needs a from-source build

RHEL 7.9 is intentionally old (glibc 2.17 — the same constraint
`../scripts/lib/platform_info.py` handles for the native installers). The base
image ships:

| Component | RHEL 7.9 base | `dnstap2` needs |
|---|---|---|
| Python | 2.7 / 3.6 | **≥ 3.11** (`../pyproject.toml`) |
| OpenSSL | 1.0.2k | **≥ 1.1.1** (required by CPython 3.10+) |

So `Dockerfile.rhel7.9` compiles **OpenSSL 1.1.1** and **CPython 3.11** from
source in a builder stage, then copies them into a lean runtime stage. Expect a
**multi-minute first build**; subsequent builds use the layer cache.

## 1. Install Docker on RHEL 7.9

If Docker isn't already present:

```bash
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
# optional: run docker without sudo
sudo usermod -aG docker "$USER"   # log out / back in to take effect
```

> RHEL 7's own repos ship the older `docker` package; the Docker CE repo above
> is the maintained path. Either works for building this image.

## 2. Get the source

The build context needs `src/` and `pyproject.toml`, so build from the repo root:

```bash
git clone https://git.marriott.com/tmsho448/DNSTAP.git
cd DNSTAP
```

## 3. Build the image

```bash
docker build -f docker/Dockerfile.rhel7.9 -t dnstap2:rhel7.9 .
```

Optional version overrides (build args):

```bash
docker build -f docker/Dockerfile.rhel7.9 \
    --build-arg PYTHON_VERSION=3.11.10 \
    --build-arg OPENSSL_VERSION=1.1.1w \
    -t dnstap2:rhel7.9 .
```

If you sit behind a corporate proxy, pass it through to the build:

```bash
docker build -f docker/Dockerfile.rhel7.9 \
    --build-arg HTTP_PROXY="$HTTP_PROXY" \
    --build-arg HTTPS_PROXY="$HTTPS_PROXY" \
    -t dnstap2:rhel7.9 .
```

## 4. Run

```bash
# print decoded events to stdout
docker run --rm -p 6000:6000 dnstap2:rhel7.9 --tcp 0.0.0.0:6000 --sink stdout

# archive to a JSONL file on the host
mkdir -p out
docker run --rm -p 6000:6000 -v "$PWD/out":/data dnstap2:rhel7.9 \
    --tcp 0.0.0.0:6000 --sink jsonl --path /data/events.jsonl

# forward to Splunk HEC (token via env, never baked into the image)
docker run --rm -p 6000:6000 -e SPLUNK_HEC_TOKEN=... dnstap2:rhel7.9 \
    --tcp 0.0.0.0:6000 --sink splunk \
    --splunk-url https://splunk.example.com:8088/services/collector/event
```

The container runs as the unprivileged user `dnstap` (uid 10001) and binds only
the high port `6000`, so no extra capabilities or root are required.

## 5. Run as a service (optional)

To keep the collector running across reboots, use a restart policy:

```bash
docker run -d --name dnstap2 --restart=unless-stopped \
    -p 6000:6000 dnstap2:rhel7.9 --tcp 0.0.0.0:6000 --sink stdout
docker logs -f dnstap2
```

For the native systemd-managed receiver (recommended in production), use
`../scripts/install_dnstap_receiver.sh` instead.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ssl module is not available` at runtime | OpenSSL 1.1.1 must build before Python in the builder stage; don't edit the stage order. Rebuild with `--no-cache`. |
| SELinux blocks the bind-mount (`Permission denied` writing `events.jsonl`) | Add `:Z` to the volume: `-v "$PWD/out":/data:Z`. |
| Firewall drops inbound dnstap | Open the port: `sudo firewall-cmd --add-port=6000/tcp --permanent && sudo firewall-cmd --reload`. |
| Build can't reach python.org / openssl.org | Pass `--build-arg HTTP_PROXY=… HTTPS_PROXY=…` (see step 3). |
| InfoBlox can't reach the host | Confirm the receiver is reachable from the grid master; on WSL2 see the networking note in `../QUICKSTART.md`. |
