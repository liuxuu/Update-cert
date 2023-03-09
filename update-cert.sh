#!/bin/bash
#####################################################
#SCRIPT NAME : update-cert                          #
#     AUTHOR : wx883696                             #
#CREATE DATE : Sat 03 Mar 2023 15:00:00 PM CST 2023 #
#####################################################

#set -xe

Passwd="dd@2019"

declare -A mapnode_label

function logger() {
  TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')
  case "$1" in
    debug)
      echo -e "$TIMESTAMP \033[36mDEBUG\033[0m $2"
      ;;
    info)
      echo -e "$TIMESTAMP \033[32mINFO\033[0m  $2"
      ;;
    warn)
      echo -e "$TIMESTAMP \033[33mWARN\033[0m  $2"
      ;;
    error)
      echo -e "$TIMESTAMP \033[31mERROR\033[0m $2"
      ;;
    *)
      ;;
  esac
}

function Check_Sshpass_Env() {
    rpm -qa | grep "sshpass" &> /dev/null

    if [[ $? -ne 0 ]];then
        logger info  "安装sshpass...";
        yum install -y epel-relese &> /dev/null
        yum install -y sshpass &> /dev/null
        if [[ $? -eq 0 ]];then
            logger info  "sshpass安装成功"
        else
            { logger error "sshpass安装失败,请手动制作master到node的免密，并重新执行脚本"; exit 1; }
        fi
    fi

    kubectl get node &> /dev/null
    if [[ $? -ne 0 ]];then
        { logger error  "执行kubectl get node命令错误,请检查"; exit 1;};
    fi

    IP_Node=""
    for i in `kubectl get node -o wide | grep -v NAME |awk '{print $6}'`;
    do
        value=$(kubectl describe node $i | grep cluster | awk -F '=' '{print $2}')
        if [[ $value == "" ]];then
           logger error "节点 $i 没有获取到cluster相关标签。"
        else
           mapnode_label[$i]=$value
           logger info "节点 $i 标签为cluster=$value"
        fi
        kubectl delete node $i &> /dev/null
        IP_Node="$i $IP_Node"
    done

    logger info  "node节点为：$IP_Node"

    for ip in $IP_Node
    do
        Check_network_passwd $ip
    done

}

function Check_network_passwd() {
    ping -c1 -W1 $1 &> /dev/null
    if [[ $? -ne 0 ]];then
      { logger error "$1 网络不通，请检查。"; exit 1;}
    fi

    sshpath="/root/.ssh/id_rsa.pub"
    [[ -f $sshpath ]] || ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa && touch /root/.ssh/authorized_keys &> /dev/null

    # 检查是否免密连接
    ssh $1 -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no "date" > /dev/null 2>&1
    if [[ $? == 0 ]];then
        logger warn "节点 $1 已免密"
    else
        if (sshpass -p $Passwd ssh -o StrictHostKeyChecking=no $1 test -e /root/.ssh/id_rsa.pub);then
           logger warn "$1 存在/root/.ssh/id_rsa.pub"
        else
           sshpass -p $Passwd ssh -o StrictHostKeyChecking=no $1 "ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa && touch /root/.ssh/authorized_keys; exit 1" &> /dev/null
        fi

        local_result=`cat $sshpath`
        remote_result=`sshpass -p $Passwd ssh -o StrictHostKeyChecking=no $1 "cat /root/.ssh/authorized_keys"`
        if [[ $remote_result = "" ]];then
            sshpass -p $Passwd ssh -o StrictHostKeyChecking=no $1 "echo $local_result > /root/.ssh/authorized_keys"
        else
            sshpass -p $Passwd ssh -o StrictHostKeyChecking=no $1 "cat /root/.ssh/authorized_keys" | while read line
            do
                if [[ $Passwd = $local_result ]];then
                   logger warn "$1 已免密"
                else
                   sshpass -p $Passwd ssh -o StrictHostKeyChecking=no $1 "echo $local_result >> /root/.ssh/authorized_keys"
                fi
            done
        fi
    fi
}

function Check_network() {
    ping -c1 -W1 $1 &> /dev/null
    if [[ $? -ne 0 ]];then
      { logger error "$1 网络不通，请检查。"; exit 1;}
    fi
}

function Read_Cluster_Env() {
    kubectl get node &> /dev/null
    if [[ $? -ne 0 ]];then
       { logger error  "执行kubectl get node命令错误,请检查"; exit 1;};
    fi

    if [[ $IP_Node == "" ]];then
        for i in `kubectl get node -o wide | grep -v NAME |awk '{print $6}'`;
        do
            kubectl delete node $i
            IP_Node="$i $IP_Node"
        done

        logger info  "node节点为：$IP_Node"

        for ip in $IP_Node
        do
            Check_network $ip
        done
    fi
}

function Change_Controller_manager() {
  logger info "Change_Controller_manager : 修改kube-controller-manager配置"
  cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kube-controller-manager Service
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=network.target
After=kube-apiserver.service
Requires=kube-apiserver.service
[Service]
Type=simple
EnvironmentFile=-/etc/kubernetes/config
EnvironmentFile=-/etc/kubernetes/controller-manager
ExecStart=/usr/local/bin/kube-controller-manager \\
        \$KUBE_LOGTOSTDERR \\
        \$KUBE_LOG_LEVEL \\
        \$KUBE_MASTER \\
        \$KUBE_CONTROLLER_MANAGER_ARGS \\
        --experimental-cluster-signing-duration=876000h0m0s \
        --feature-gates=RotateKubeletServerCertificate=true

Restart=always
LimitNOFILE=65536

[Install]
WantedBy=default.target

EOF
  logger info "Change_Controller_manager : 重启kube-controller-manager"
systemctl daemon-reload
systemctl restart kube-controller-manager
}

function Setup() {
    ssh $1 "$(typeset -f logger Change_kubelet); Change_kubelet $1"
}

function Change_kubelet() {
  logger info "Change_kubelet : 修改节点 $1 kubelet配置"
  logger info "Change_kubelet : 删除节点 $1 kubelet证书"
rm -f /etc/kubernetes/kubernetesTLS/kubelet*
      cat > /usr/lib/systemd/system/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=docker.service
Requires=docker.service
[Service]
EnvironmentFile=-/etc/kubernetes/config
EnvironmentFile=-/etc/kubernetes/kubelet
ExecStart=/usr/local/bin/kubelet \\
            \$KUBE_LOGTOSTDERR \\
            \$KUBE_LOG_LEVEL \\
            \$KUBELET_CONFIG\\
            \$KUBELET_ADDRESS \\
            \$KUBELET_PORT \\
            \$KUBELET_HOSTNAME \\
            \$KUBELET_POD_INFRA_CONTAINER \\
            \$KUBELET_ARGS \\
            --feature-gates=RotateKubeletServerCertificate=true \\
            --feature-gates=RotateKubeletClientCertificate=true \\
            --rotate-certificates
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  logger info "Change_kubelet : 重启节点 $1 kubelet"
systemctl daemon-reload
systemctl restart kubelet
}

function Rejoin_Cluster() {
    logger info "Rejoin_Cluster : 重新加入集群"
    sleep 5
    kubectl get csr | grep -v NAME | grep Pending &> /dev/null
    if [[ $? -eq 0 ]];then

       Join_node=`kubectl get csr | grep -v NAME | grep Pending | cut -d " " -f 1`

       for i in $Join_node
       do
          kubectl certificate approve $i
       done

       logger info "Rejoin_Cluster : 执行命令 \"kubectl get node -o wide\" 请等待节点就绪..."

#       while true
#       do
#           sleep 10
#          kubectl get node | grep "NotReady" > /dev/null
#           if [[ $? -eq 0 ]];then
#              break
#           fi
#       done

       for ((i=0; i<=10; i++))do

           sleep 15
           result=$(echo $(kubectl get node | grep -v NAME | awk '{print $2}') | grep "NotReady")

           kubectl get node -o wide

           if [[ "$result" != "" ]];then
              continue
           else
              break
           fi
       done
    else
       logger error "Rejoin_Cluster : 获取 \"kubectl get csr | grep -v NAME | grep Pending\" 失败。"
    fi
}

function Add_Node_Label() {
    logger info "重新添加节点 $1 标签 cluster=${mapnode_label[$1]}"

    if [[ ${mapnode_label[@]} == "" ]];then
        { logger error "没有获取到集群节点标签 cluster=app/lab";exit 1; }
    fi

    if [[ ${mapnode_label[$1]} == "" ]];then
        { logger error "没有获取到该节点 $1 标签 cluster=app/lab"; }
    fi

    if [[ ${mapnode_label[$1]} != "" ]];then
        kubectl label node $1 cluster=${mapnode_label[$1]} &>/dev/null
    fi
}

function Add_Csr_Ask() {
    logger info "添加集群CSR证书轮换请求"

      cat > /tmp/tls-instructs-csr.yml << EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeserver
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests/selfnodeserver"]
  verbs: ["create"]
EOF

kubectl apply -f /tmp/tls-instructs-csr.yml &>/dev/null

    kubectl get clusterrolebinding node-client-auto-approve-csr &>/dev/null
    if [[ $? -ne 0 ]];then
        kubectl create clusterrolebinding node-client-auto-approve-csr --clusterrole=system:certificates.k8s.io:certificatesigningrequests:nodeclient --user=kubelet-bootstrap & >/dev/null
    fi

    kubectl get clusterrolebinding node-client-auto-renew-crt &>/dev/null
    if [[ $? -ne 0 ]];then
        kubectl create clusterrolebinding node-client-auto-renew-crt --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeclient --group=system:nodes & >/dev/null
    fi

    kubectl get clusterrolebinding node-server-auto-renew-crt &>/dev/null
    if [[ $? -ne 0 ]];then
        kubectl create clusterrolebinding node-server-auto-renew-crt --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeserver --group=system:nodes & >/dev/null
    fi

    logger info "执行结束：可在Node节点执行以下命令查验 kubelet 证书签发时长"

    echo -e "\033[0;31;1mcd /etc/kubernetes/kubernetesTLS/ \033[0m"
    echo -e "\033[0;31;1mopenssl x509 -in kubelet-client-current.pem -noout -text| grep Not \033[0m"

    logger info "后续请查看服务容器启动是否正常"

}

function Disposable_Install() {
    Check_Sshpass_Env
    Read_Cluster_Env
    Change_Controller_manager
    for ip in $IP_Node
    do
        Setup $ip
    done
    Rejoin_Cluster
    for ip in $IP_Node
    do
        Add_Node_Label $ip
    done
    Add_Csr_Ask
}

function main() {

  [[ "$EUID" -ne 0 ]] && { logger error "你应该用 root 用户执行此脚本"; exit 1; }

  Disposable_Install

}

main