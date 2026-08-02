# Container Runtime (containerd)

## Цель

Понять **CRI**, **OCI**, **containerd**, **runc**, **shim** и **sandbox (pause) container**; установить и настроить **containerd** с **`SystemdCgroup=true`** на lab nodes; проверить runtime через **crictl** и **ctr** - перед установкой kubelet.

---

## Теория

### Зачем kubelet не запускает Docker напрямую

С Kubernetes **1.24+** in-tree support **dockershim** удалён. Kubelet общается только через **CRI (Container Runtime Interface)** - gRPC API.

```
                    ┌─────────────────────────────────┐
                    │           kubelet               │
                    └───────────────┬─────────────────┘
                                    │ CRI gRPC
                    ┌───────────────▼─────────────────┐
                    │  containerd (или CRI-O)       │
                    │  ┌─────────┐  ┌─────────────┐ │
                    │  │ CRI     │  │ containerd│ │
                    │  │ plugin  │  │ core        │ │
                    │  └────┬────┘  └──────┬──────┘ │
                    └───────┼──────────────┼─────────┘
                            │              │
                            ▼              ▼
                         runc         image pull (registry)
                            │
                            ▼
                      OCI container
```

**Talos homelab:** containerd тоже runtime (Talos default), но конфиг **managed** - вы не правите `/etc/containerd/config.toml` через SSH.

---

### OCI (Open Container Initiative)

**Стандарты:**

| Спецификация | Что определяет |
|--------------|----------------|
| **Runtime Spec** | config.json, lifecycle (create/start/kill) |
| **Image Spec** | manifest, layers, config |

**runc** - reference OCI runtime: создаёт namespaces, cgroups, rootfs из layers.

```
Image (registry.k8s.io/pause:3.10)
       │
       ▼ pull + unpack layers
  /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
       │
       ▼ runc create/start
  process in namespaces (PID, NET, MNT, ...)
```

---

### containerd architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        containerd daemon                      │
│  ┌────────────┐  ┌─────────────┐  ┌────────────────────────┐  │
│  │ Content    │  │ Snapshotter │  │ Metadata (boltdb)      │  │
│  │ store      │  │ (overlayfs) │  │ containers, images     │  │
│  └────────────┘  └─────────────┘  └────────────────────────┘  │
│         ▲              ▲                      ▲               │
│         │              │                      │               │
│  ┌──────┴──────────────┴──────────────────────┴──────────┐  │
│  │                    CRI Plugin (cri)                      │  │
│  └──────────────────────────┬───────────────────────────────┘  │
└─────────────────────────────┼────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
    containerd-shim      containerd-shim      containerd-shim
    (per container)      (per container)      (pause sandbox)
         │                    │                    │
         ▼                    ▼                    ▼
       runc                  runc                  runc
```

**containerd-shim:** родитель runc после старта - daemon не держит дочерние процессы; shim reparents под systemd, собирает exit codes.

---

### Sandbox (pause) container

**Pod** в Kubernetes = один **Pod sandbox** + N application containers.

```
Pod (UID abc-123)
  │
  ├── sandbox (pause:3.10)     ← holds NET namespace, IPC
  │       │
  │       ├── veth ──► CNI assigns IP
  │       │
  ├── container: nginx         ← joins sandbox NET
  └── container: sidecar       ← same NET namespace
```

**pause container:** минимальный процесс, **sleep infinity** - держит namespace живым, пока app containers restart.

**Kubelet flow:**

1. `RunPodSandbox` (CRI) → pause + network.
2. `CreateContainer` / `StartContainer` для каждого container в Pod.
3. `StopPodSandbox` при удалении Pod.

---

### CRI API (основные вызовы)

| RPC | Кто вызывает | Действие |
|-----|--------------|----------|
| `RunPodSandbox` | kubelet | pause + network |
| `CreateContainer` | kubelet | create filesystem |
| `StartContainer` | kubelet | run process |
| `PullImage` | kubelet | download image |
| `StopPodSandbox` | kubelet | teardown |
| `RemoveContainer` | kubelet | cleanup |

**crictl** - CLI для отладки CRI (не production tool, но CKA must).

---

### SystemdCgroup=true

**Проблема:** kubelet и containerd должны согласованно управлять **cgroups** (CPU/memory limits Pod).

| `SystemdCgroup` | Поведение |
|-----------------|-----------|
| **false** (legacy cgroupfs) | containerd cgroup driver ≠ kubelet systemd → **fail** или unstable |
| **true** | containerd создаёт cgroups через **systemd** - **match kubelet** on Ubuntu |

**kubeadm/kubelet default на systemd distros:** `cgroupDriver: systemd`

```toml
# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

**Симптом mismatch:** kubelet CrashLoop, `cgroup driver mismatch`.

---

### containerd vs CRI-O vs Docker Engine

| Runtime | Использование |
|---------|---------------|
| **containerd** | kubeadm default, Talos, EKS, GKE node |
| **CRI-O** | OpenShift, RHEL-focused |
| **Docker Engine** | dev; нужен **cri-dockerd** shim для kubelet |

**Lab:** **containerd** из Ubuntu 24.04 или upstream + kubeadm docs.

---

### Production best practices

| Практика | Детали |
|----------|--------|
| Pin containerd version | совместимость с k8s 1.32 |
| `SystemdCgroup=true` | always on systemd nodes |
| Registry mirror / pull-through | air-gapped, rate limits |
| Separate disk for `/var/lib/containerd` | image layers IO |
| `crictl` только debug | не управлять prod workloads |
| Image signature (cosign) | supply chain - см. 15.3 |

**Типичные ошибки:**

- забыли `systemctl restart containerd` после config.toml;
- sandbox image не pulled → Pod stuck;
- используют `docker` CLI вместо `crictl` для K8s pods;
- старый `cri-docker.sock` path в kubelet.

---

## Практика

### Цель

Установить **containerd**, сгенерировать config с **SystemdCgroup**, проверить **crictl** и **ctr** на **k8s-cp-01** (и workers до join).

### Зачем

kubelet **не стартует** без working CRI socket: `/run/containerd/containerd.sock`.

### Шаг 1 - prep уже выполнен (15.5.2)

```bash
sysctl net.ipv4.ip_forward
swapon --show   # empty
```

### Шаг 2 - install containerd

```bash
cd /tmp/install-kubeadm/scripts
chmod +x 01-install-containerd.sh
sudo ./01-install-containerd.sh
```

**Ожидаемые действия скрипта:**

| # | Команда / действие |
|---|-------------------|
| 1 | `apt-get update` |
| 2 | install `containerd` package (Ubuntu 24.04) |
| 3 | `containerd config default > /etc/containerd/config.toml` |
| 4 | enable `SystemdCgroup = true` in runc options |
| 5 | `systemctl enable --now containerd` |
| 6 | install `crictl` (optional in script) |

### Шаг 3 - verify systemd + socket

```bash
systemctl status containerd --no-pager
ls -la /run/containerd/containerd.sock
```

**Ожидаемый результат:** `active (running)`, socket exists.

### Шаг 4 - verify SystemdCgroup

```bash
grep -A5 runc.options /etc/containerd/config.toml
# SystemdCgroup = true
```

### Шаг 5 - crictl config

```bash
cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

sudo crictl info | head -20
sudo crictl ps -a    # пусто до kubelet
```

### Шаг 6 - ctr (low-level containerd CLI)

```bash
# Pull pause image (same family kubeadm uses)
sudo ctr -n k8s.io images pull registry.k8s.io/pause:3.10
sudo ctr -n k8s.io images ls | grep pause
```

**Зачем ctr:** debug **без** kubelet - image store, namespaces (`k8s.io` для CRI).

### Шаг 7 - contrast Talos (read-only)

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'
```

**Ожидаемый результат:** `containerd://1.x.x` на Talos nodes.

### Verify

| Check | Command | Expected |
|-------|---------|----------|
| daemon running | `systemctl is-active containerd` | active |
| CRI socket | `test -S /run/containerd/containerd.sock` | OK |
| SystemdCgroup | grep config.toml | true |
| pause image | `ctr -n k8s.io images ls` | pause:3.10 |

### Rollback

```bash
sudo systemctl stop containerd
sudo apt-get remove -y containerd crictl 2>/dev/null
sudo rm -rf /etc/containerd /var/lib/containerd /etc/crictl.yaml
sudo systemctl daemon-reload
# VM snapshot restore - preferred for full rollback
```

---

## Что произошло внутри Kubernetes

**До kubelet** Kubernetes objects не создаются. На host:

```
01-install-containerd.sh
         │
         ▼
systemd starts containerd
         │
         ├── loads /etc/containerd/config.toml
         ├── enables CRI plugin on unix socket
         └── snapshotter overlayfs ready (needs overlay module)

ctr pull pause:3.10
         │
         ├── HTTP pull registry.k8s.io
         ├── unpack layers → overlayfs snapshots
         └── image metadata in containerd DB

(Позже kubelet)
         │
         ├── connects CRI socket
         ├── RunPodSandbox → pause container
         └── PullImage nginx → same pipeline
```

---

## Troubleshooting

| Симптом | Причина | Решение |
|---------|---------|---------|
| `containerd.sock: no such file` | daemon down | `systemctl start containerd` |
| kubelet: cgroup driver mismatch | SystemdCgroup false | fix config.toml, restart |
| `failed to pull image` | no internet, DNS | curl registry, mirror |
| overlay mount fail | no overlay module | `modprobe overlay`, 15.5.2 |
| crictl: endpoint not found | wrong crictl.yaml | unix socket path |
| Pods Unknown after manual ctr rm | bypass kubelet | never delete k8s containers via ctr in prod |
| high disk use | old images | `crictl rmi --prune` (careful) |

---
