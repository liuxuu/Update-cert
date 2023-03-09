# Update-cert

因Kubernetes集群如果不设置相关参数，默认签发的kubelet证书为一年有效期，通过此脚本可修改为100年有效期；

## 使用方法

```shell
# 需在集群master节点任意位置执行
wget https://jiaofu-tools.obs.cn-east-2.myhuaweicloud.com/Update-cert
chmod +x Update-cert
```

需在脚本中修改服务器密码为自己环境的密码

![](https://gitee.com/lxzj2016/picture/raw/master/img/20230309144819.png)

### 执行

```shell
./Update-cert
```