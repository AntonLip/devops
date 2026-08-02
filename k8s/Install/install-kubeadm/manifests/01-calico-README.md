# Calico CNI — установка через upstream manifest
#
# Скрипт 05-install-calico.sh скачивает с GitHub:
#   https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
#
# ВАЖНО: pod-network-cidr при kubeadm init = 10.244.0.0/16
#
# Вручную:
#   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
#
# Этот файл — справка, не kubectl manifest (нет apiVersion).
