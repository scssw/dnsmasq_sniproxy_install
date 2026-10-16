# Dnsmasq SNIproxy One-click Install
# 解锁GPT和Gemini
### 脚本说明：

* 原理简述：使用[Dnsmasq](http://thekelleys.org.uk/dnsmasq/doc.html)的DNS将网站解析劫持到[SNIproxy](https://github.com/dlundquist/sniproxy)反向代理的页面上。

* 用途：让无法观看流媒体的VPS可以观看（前提：VPS中要有一个是能观看流媒体的）。

* 特性：脚本解锁`CHATGPT和Gemini`[点击查看解锁域名](https://github.com/scssw/dnsmasq_sniproxy_install/blob/master/proxy-domains.txt)。域名清单是 dnsmasq 与 sniproxy 规则的唯一来源，新增域名后使用同步工具更新两边配置。

* 脚本支持系统：CentOS6+, Debian8+, Ubuntu16+
    * 理论上支持上述系统及不限制虚拟化类型，如有问题请反馈
    * 如果脚本最后显示的IP和实际公网IP不符，请修改一下文件`/etc/sniproxy.conf`中的IP地址

### 脚本用法：

    bash dnsmasq_sniproxy.sh [-h] [-i] [-f] [-id] [-fd] [-is] [-fs] [-u] [-ud] [-us]
      -h , --help                显示帮助信息
      -i , --install             安装 Dnsmasq + SNI Proxy
      -f , --fastinstall         快速安装 Dnsmasq + SNI Proxy
      -id, --installdnsmasq      仅安装 Dnsmasq
      -fd, --installdnsmasq      快速安装 Dnsmasq
      -is, --installsniproxy     仅安装 SNI Proxy
      -fs, --fastinstallsniproxy 快速安装 SNI Proxy
      -u , --uninstall           卸载 Dnsmasq + SNI Proxy
      -ud, --undnsmasq           卸载 Dnsmasq
      -us, --unsniproxy          卸载 SNI Proxy

### 快速安装（推荐）：
``` Bash
wget -O dnsmasq_sniproxy.sh https://raw.githubusercontent.com/scssw/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh && bash dnsmasq_sniproxy.sh -f
```

### 普通安装：
``` Bash
wget -O dnsmasq_sniproxy.sh https://raw.githubusercontent.com/scssw/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh && bash dnsmasq_sniproxy.sh -i
```

### 卸载方法：
``` Bash
wget -O dnsmasq_sniproxy.sh https://raw.githubusercontent.com/scssw/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh && bash dnsmasq_sniproxy.sh -u
```

### 配置检查与同步（SNIProxy 规则更新）

当 `proxy-domains.txt` 域名清单新增或更新后，直接同步并更新 `/etc/sniproxy.conf` 配置，无需重新安装服务：

```bash
# 检查当前 /etc/sniproxy.conf 中的域名规则是否完整
curl -fsSL https://raw.githubusercontent.com/scssw/dnsmasq_sniproxy_install/master/sync-proxy-config.sh | bash -s -- check

# 升级 /etc/sniproxy.conf 并重启 sniproxy 服务（默认仅升级 sniproxy，无需传参）
curl -fsSL https://raw.githubusercontent.com/scssw/dnsmasq_sniproxy_install/master/sync-proxy-config.sh | sudo bash -s -- update
```

- **默认行为**：`update` 会自动备份 `/etc/sniproxy.conf`，将域名清单的完整规则替换至 `/etc/sniproxy.conf` 的 `table` 块中，并重启 `sniproxy` 服务（无需提供代理 IPv4 参数，不操作/不重启 dnsmasq，避免因 53 端口冲突或未运行导致报错中断）。
- **扩展用法**：若需同步 Dnsmasq 或同时更新两边配置，可显式指定目标及代理服务器 IPv4：
  ```bash
  # 同时更新 sniproxy 与 dnsmasq
  sudo ./sync-proxy-config.sh update all 203.0.113.10
  # 仅更新 dnsmasq
  sudo ./sync-proxy-config.sh update dnsmasq 203.0.113.10
  ```

### 使用方法：
将代理主机的DNS地址修改为安装过dnsmasq的主机IP即可，如果不可用，尝试配置文件中仅保留一个DNS地址。

防止滥用，建议不要公开IP地址，可以使用防火墙做好限制工作。

### 调试排错：
- 确认sniproxy有效运行

  查看sniproxy状态：`systemctl status sniproxy`

  如果sniproxy不在运行，检查一下是否有其他服务占用80,443端口，导致端口冲突，查看端口监听命令：`netstat -tlunp | grep 443`

- 确认防火墙放行53,80,443

  调试可直接关闭防火墙 `systemctl stop firewalld.service`

  阿里云/谷歌云/AWS等运营商安全组端口同样需要放行
  可通过其他服务器 `telnet 1.2.3.4 53` 进行测试

- 解析域名测试

  尝试用其他服务器配置完毕dns后，解析域名：nslookup netflix.com 判断IP是否是NETFLIX代理机器IP
  如果不存在nslookup命令，centos安装：`yum install -y bind-utils` ubuntu&debian安装：`apt-get -y install dnsutils`

- systemd-resolve服务占用53端口解决方法
  使用`netstat -tlunp|grep 53`发现53端口被systemd-resolved占用了
  修改`/etc/systemd/resolved.conf`
  ```
  [Resolve]
  DNS=8.8.8.8 1.1.1.1 #取消注释，增加dns
  #FallbackDNS=
  #Domains=
  #LLMNR=no
  #MulticastDNS=no
  #DNSSEC=no
  #Cache=yes
  DNSStubListener=no  #取消注释，把yes改为no
  ```
  接着再执行以下命令，并重启systemd-resolved
  ```
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved.service
  ```

---

___本脚本仅限解锁流媒体使用___
