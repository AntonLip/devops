# kubeadm init

## Цель

Разобрать **каждую фазу** `kubeadm init`: preflight, certificates, kubeconfig, control plane static pods, etcd, bootstrap token, addons; знать **все сертификаты** в `/etc/kubernetes/pki`; выполнить init на **k8s-cp-01** с **`--pod-network-cidr`** и понять **полный внутренний flow**.

---

## Теория

### Что делает kubeadm init (overview)

`kubeadm init` - **не** «магический installer». Это orchestrator **локальных** шагов на первой control plane node:

```
kubeadm init
     │
     ├── [preflight]      проверки OS, ports, containerd, versions
     ├── [certs]          PKI в /etc/kubernetes/pki
     ├── [kubeconfig]     admin.conf, controller-manager.conf, ...
     ├── [control-plane]  static pod manifests → /etc/kubernetes/manifests/
     ├── [etcd]           etcd.yaml manifest (local stacked)
     ├── [wait-control-plane]  API /healthz live
     ├── [upload-config]  kubeadm-config ConfigMap (optional phases)
     ├── [bootstrap-token]  token для worker join + RBAC
     ├── [kubelet-finalize]  kubelet drop-in, client cert rotation
     └── [addon]          CoreDNS + kube-proxy Deployments
```

**Contrast Talos:** `talosctl bootstrap` + machine config - **нет** `/etc/kubernetes/manifests` на SSH; здесь **видим каждый файл**.

---

### Preflight phase

**Зачем:** fail fast до генерации certs и запуска etcd.

| Check | Пример fail |
|-------|-------------|
| swap | swap enabled |
| port 6443 | already in use |
| container runtime | socket missing |
| kernel modules | br_netfilter |
| crictl / images | cannot pull pause |
| CPU/RAM | warnings |
| hostname | empty / invalid |
| file paths | `/etc/kubernetes` exists (re-init) |

```bash
kubeadm init phase preflight
# или dry-run:
kubeadm init --dry-run
```

**Production:** fix **all** ERROR; WARN - document (например single-node).

---

### Certificates phase

**Зачем:** весь control plane на **mTLS** - API, etcd, kubelet, front-proxy.

**CA hierarchy:**

```
/etc/kubernetes/pki/
├── ca.crt / ca.key              ← cluster CA (Kubernetes)
├── apiserver.crt / apiserver.key
├── apiserver-kubelet-client.crt / .key
├── front-proxy-ca.crt / front-proxy-ca.key
├── front-proxy-client.crt / front-proxy-client.key
├── sa.key / sa.pub              ← ServiceAccount token signing (legacy compat)
└── etcd/
    ├── ca.crt / ca.key          ← etcd CA (может совпадать или отдельный)
    ├── server.crt / server.key  ← etcd member
    └── peer.crt / peer.key      ← etcd peer communication
```

#### Таблица сертификатов (полная)

| File | Subject / usage | Valid for |
|------|-----------------|-----------|
| `ca.crt` | CN=kubernetes | Sign cluster certs |
| `ca.key` | **PRIVATE** - backup encrypted | - |
| `apiserver.crt` | CN=kube-apiserver | SAN: API IP, DNS, Service IP |
| `apiserver.key` | API server TLS | - |
| `apiserver-kubelet-client.crt` | O=system:masters | apiserver → kubelet |
| `apiserver-kubelet-client.key` | | |
| `front-proxy-ca.crt` | aggregator CA | extension apiserver |
| `front-proxy-ca.key` | | |
| `front-proxy-client.crt` | CN=front-proxy-client | requestheader auth |
| `front-proxy-client.key` | | |
| `sa.key` / `sa.pub` | ServiceAccount | token signing |
| `etcd/ca.crt` | etcd CA | |
| `etcd/ca.key` | **PRIVATE** | |
| `etcd/server.crt` | etcd server | localhost, node IP |
| `etcd/server.key` | | |
| `etcd/peer.crt` | etcd peer | member ↔ member |
| `etcd/peer.key` | | |

**SAN на apiserver.crt (typical):**

- `kubernetes` (Service name)
- `kubernetes.default.svc`
- `kubernetes.default.svc.cluster.local`
- `<node IP>` (192.168.1.20)
- `<hostname>` (k8s-cp-01)
- `10.96.0.1` (ClusterIP of kubernetes Service)

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A1 'Subject Alternative Name'
```

**Rotation:** `kubeadm certs renew all` (before expiry - 1 year default).
**Production:** backup **ca.key**, **etcd/ca.key** offline encrypted; loss = rebuild cluster.

---

### Kubeconfig phase

**Файлы в `/etc/kubernetes/`:**

| File | User / purpose |
|------|----------------|
| `admin.conf` | `kubernetes-admin` - cluster-admin |
| `super-admin.conf` | super-admin (1.29+) optional break-glass |
| `controller-manager.conf` | `system:kube-controller-manager` |
| `scheduler.conf` | `system:kube-scheduler` |
| `kubelet.conf` | `system:node:<hostname>` bootstrap → rotated |

**Structure:**

```yaml
clusters:
  - cluster:
      certificate-authority-data: <ca.crt base64>
      server: https://192.168.1.20:6443
    name: kubernetes
contexts:
  - context:
      cluster: kubernetes
      user: kubernetes-admin
    name: kubernetes-admin@kubernetes
current-context: kubernetes-admin@kubernetes
users:
  - name: kubernetes-admin
    user:
      client-certificate-data: ...
      client-key-data: ...
```

**После init:**

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

### Control plane phase (static pods)

**Manifests → `/etc/kubernetes/manifests/`:**

| File | Pod | Image (1.32) |
|------|-----|--------------|
| `kube-apiserver.yaml` | kube-apiserver | registry.k8s.io/kube-apiserver:v1.32.x |
| `kube-controller-manager.yaml` | kube-controller-manager | ... |
| `kube-scheduler.yaml` | kube-scheduler | ... |
| `etcd.yaml` | etcd | registry.k8s.io/etcd:3.5.x |

**Static pod mechanism:**

```
File written to /etc/kubernetes/manifests/etcd.yaml
         │
         ▼
kubelet file watcher (inotify)
         │
         ▼
kubelet creates mirror pod via API (optional visibility)
         │
         ▼
CRI RunPodSandbox + containers
         │
         ▼
Pod Running - API server can start (etcd first!)
```

**Порядок запуска (упрощённо):**

1. **etcd** - state store.
2. **kube-apiserver** - connects etcd.
3. **scheduler**, **controller-manager** - connect API.

---

### etcd phase (stacked)

**Local etcd** - static pod на **same node** as CP.

```
etcd pod
  ├── listen client 127.0.0.1:2379 (and/or node IP)
  ├── data dir: /var/lib/etcd
  └── TLS: /etc/kubernetes/pki/etcd/
```

**Flags in manifest:** `--initial-cluster-state=new`, `--name=k8s-cp-01`, `--initial-advertise-peer-urls`.
**HA (preview 15.5.15):** 3 members, `--initial-cluster=cp1=...,cp2=...,cp3=...`.

---

### wait-control-plane phase

kubeadm polls **`https://localhost:6443/healthz`** until OK.
**Timeout symptoms:** etcd data dir corrupt, apiserver cert wrong SAN, port conflict.

---

### bootstrap-token phase

**Зачем:** worker **без** pre-shared admin cert должен **безопасно** присоединиться.

```
Bootstrap Token (Secret in kube-system)
         │
         ├── token ID + secret (join command)
         ├── RBAC: allow CSR for kubelet client cert
         └── expires (default 24h, configurable)

Worker: kubeadm join → TLS bootstrap → CSR approved → kubelet cert
```

**Join command (пример output init):**

```bash
kubeadm join 192.168.1.20:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

**`discovery-token-ca-cert-hash`:** pin CA - MITM protection.

---

### addon phase

| Addon | Type | Namespace |
|-------|------|-----------|
| **kube-proxy** | DaemonSet | kube-system |
| **CoreDNS** | Deployment | kube-system |

**Важно:** **CNI (Calico) НЕ ставится kubeadm** - вы ставите в 15.5.9.
**Без CNI:** nodes могут быть **NotReady** или pods **ContainerCreating** forever.

---

### Критичные флаги init для lab

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.20 \
  --control-plane-endpoint=192.168.1.20 \
  --kubernetes-version=v1.32.x \
  --cri-socket=unix:///run/containerd/containerd.sock
```

| Flag | Зачем |
|------|-------|
| `--pod-network-cidr` | Calico IPAM / routing |
| `--apiserver-advertise-address` | cert SAN, kubelet connect |
| `--control-plane-endpoint` | stable API address (single IP lab; HA = LB DNS) |
| `--kubernetes-version` | pin exact patch |
| `--cri-socket` | explicit containerd |

**Service CIDR default:** `10.96.0.0/12` - не пересекается с pod/node CIDR.

---

### Production best practices

| Практика | Детали |
|----------|--------|
| `--control-plane-endpoint` = LB DNS | not single node IP |
| `--upload-certs` for HA join | encrypt certs share |
| Backup PKI + etcd **before** changes | 15.5.17 |
| `--skip-phases=addon/kube-proxy` | if Cilium kube-proxy replacement |
| Document join token expiry | rotate with `kubeadm token create` |
| Don't re-init lightly | destroys etcd data |

**Типичные ошибки:**

- forgot `--pod-network-cidr` → Calico mismatch;
- wrong `--apiserver-advertise-address` → kubelet can't reach API;
- re-run init on dirty `/etc/kubernetes` → preflight fail;
- lose `admin.conf` → need recovery from /etc/kubernetes/pki;
- nodes Ready but pods stuck → **no CNI**.

---

## Практика

### Цель

Выполнить **`kubeadm init`** на **k8s-cp-01** через [`03-kubeadm-init.sh`](./install-kubeadm/scripts/03-kubeadm-init.sh) или вручную; настроить kubectl; изучить созданные файлы.

### Зачем

Это **moment of truth** - control plane birth; все последующие главы опираются на эти paths.

### Предусловия

- 15.5.2 prep ✓
- 15.5.3 containerd ✓
- 15.5.4 packages 1.32.x ✓
- **Clean** `/etc/kubernetes` - first init only

### Шаг 1 - final preflight

```bash
sudo kubeadm reset -f 2>/dev/null   # ONLY if re-run lab; destroys cluster!
sudo kubeadm init phase preflight
sudo crictl info | head -3
free -h
```

### Шаг 2 - run init script

```bash
cd /tmp/install-kubeadm/scripts
chmod +x 03-kubeadm-init.sh
sudo ./03-kubeadm-init.sh
# или manual command from script / theory above
```

**Сохраните весь output** - содержит **join command** для workers.

### Шаг 3 - configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl get nodes
kubectl get pods -n kube-system
```

**Ожидаемый результат (сразу после init, **до CNI**):**

```
NAME         STATUS     ROLES           AGE   VERSION
k8s-cp-01    NotReady   control-plane   1m    v1.32.x

kube-system pods: etcd, apiserver, scheduler, CM, coredns (Pending), kube-proxy (Pending/Running)
```

**NotReady без CNI - ожидаемо** до Calico (15.5.9).

### Шаг 4 - explore PKI

```bash
sudo ls -la /etc/kubernetes/pki/
sudo ls -la /etc/kubernetes/pki/etcd/
sudo ls -la /etc/kubernetes/manifests/
```

**Заполните таблицу (упражнение):**

| File exists? | Purpose |
|--------------|---------|
| ca.crt | |
| apiserver.crt | |
| etcd/server.crt | |
| sa.pub | |

### Шаг 5 - inspect static pod manifest

```bash
sudo grep -E 'image:|command:' /etc/kubernetes/manifests/kube-apiserver.yaml | head -10
sudo grep -E 'etcd-data|listen-client' /etc/kubernetes/manifests/etcd.yaml
```

### Шаг 6 - verify API health

```bash
kubectl cluster-info
kubectl get componentstatuses 2>/dev/null || kubectl get --raw='/healthz?verbose'
curl -k https://127.0.0.1:6443/healthz
```

### Шаг 7 - bootstrap token

```bash
kubeadm token list
kubectl get secrets -n kube-system | grep bootstrap-token
```

### Шаг 8 - save join command

```bash
# From init output or regenerate:
kubeadm token create --print-join-command
```

**Храните** для 15.5.8 worker join.

### Шаг 9 - contrast Talos (read-only)

```bash
# On laptop with Talos context - NOT on kubeadm node
kubectl config use-context <talos-context>
kubectl get pods -n kube-system -l tier=control-plane
# Compare: same logical components, different install path
```

### Verify

| Check | Expected |
|-------|----------|
| `kubectl get nodes` | k8s-cp-01 visible |
| `/etc/kubernetes/pki/ca.crt` | exists |
| `kubectl get pods -n kube-system` | etcd + apiserver Running |
| API healthz | ok |
| join command saved | yes |

### Rollback

**⚠️ Destructive - только lab VM:**

```bash
# Drain not needed on single CP with no workloads
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd $HOME/.kube/config
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo systemctl restart containerd kubelet
# Restore VM snapshot - cleanest
```

---

## Что произошло внутри Kubernetes

```
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 ...
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: preflight                                                 │
│   swap, ports, containerd.sock, version 1.32.x                  │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: certs                                                     │
│   Generate CA, apiserver, etcd, front-proxy, SA keys            │
│   Write /etc/kubernetes/pki/**                                   │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: kubeconfig                                                │
│   admin.conf, scheduler.conf, controller-manager.conf, kubelet  │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: control-plane + etcd                                      │
│   Write manifests: etcd.yaml, kube-apiserver.yaml, ...          │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
                    kubelet watches manifests/
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
    etcd container     apiserver container   scheduler, CM
         │                   │
         │                   └──► listens :6443
         └──► /var/lib/etcd data
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: wait-control-plane                                        │
│   kubeadm → GET /healthz → OK                                    │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: bootstrap-token                                           │
│   Secret bootstrap-token-* in kube-system                        │
│   ClusterRoleBindings for CSR auto-approve (node bootstrap)      │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ PHASE: addon                                                     │
│   kube-proxy DS, CoreDNS Deployment in kube-system               │
│   (CNI still MISSING - Calico in 15.5.9)                         │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
              Cluster API alive, CP node NotReady (no CNI)
                             │
                             ▼
         You: kubectl get nodes / pods - observe state
```

**etcd first, API second** - без etcd apiserver не стартует; без API scheduler/CM не config complete.

---

## Troubleshooting

| Симптом | Причина | Решение |
|---------|---------|---------|
| preflight: `/etc/kubernetes exists` | previous init | `kubeadm reset` or clean VM |
| `port 6443 already in use` | stale process | `kubeadm reset`, kill process |
| apiserver CrashLoop | etcd not up, certs | `crictl logs` apiserver container |
| etcd CrashLoop | permissions / disk | `chown etcd /var/lib/etcd`, check manifest |
| `certificate signed by unknown authority` | wrong kubeconfig | cp admin.conf again |
| Node NotReady | **no CNI** | expected; install Calico 15.5.9 |
| CoreDNS Pending | no CNI / taints | after CNI |
| join token expired | 24h default | `kubeadm token create` |
| wrong SAN on cert | bad advertise-address | re-init with correct IP |
| pause image pull fail | no registry access | proxy, mirror |

**Диагностика:**

```bash
sudo crictl ps -a | grep -E 'etcd|apiserver'
sudo crictl logs <apiserver-container-id>
sudo journalctl -u kubelet -f
kubectl get events -n kube-system --sort-by='.lastTimestamp'
```

---
