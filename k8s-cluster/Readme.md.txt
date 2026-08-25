.\vm.ps1 start-all
.\vm.ps1 stop-all
.\vm.ps1 status-all

.\vm.ps1 start k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1
.\vm.ps1 stop k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1
.\vm.ps1 restart k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1
.\vm.ps1 force-stop k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1
.\vm.ps1 status k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1
.\vm.ps1 list