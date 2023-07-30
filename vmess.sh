#!/bin/bash

# 全局变量
V2RAY_VERSION=4.45.0

INSTALL_DIR=/usr/local/v2ray
CONFIG_FILE=${INSTALL_DIR}/etc/v2ray/config.json

INFO_FILE=${INSTALL_DIR}/v2ray_info.txt

NGINX_VERSION=1.18.0
NGINX_INSTALL_DIR=/usr/local/nginx
NGINX_CONF_FILE=${NGINX_INSTALL_DIR}/conf/nginx.conf

LOG_FILE=/var/log/v2ray_install.log

# 输出格式
INFO="[Info]"
SUCCESS="[OK]"
ERROR="[Error]"

# ==========函数定义开始=========

# 记录日志
log() {
  echo "$(date +"%Y-%m-%d %H:%M:%S") $1" >> ${LOG_FILE}  
}

# 检查环境
check_env() {
  # 检查是否为 Root 用户
  if [ "$(id -u)" != "0" ]; then
     echo -e "${ERROR} 当前用户不是 Root 用户,请切换到 Root 用户后重新执行脚本!"
     exit 1
  fi

  # 检查系统信息
  source '/etc/os-release'

  if [[ "$ID" == "centos" && ${VERSION_ID} -ge 7 ]]; then
     log "当前系统为 CentOS ${VERSION_ID} ${VERSION}"
  elif [[ "$ID" == "debian" && ${VERSION_ID} -ge 8 ]]; then
     log "当前系统为 Debian ${VERSION_ID} ${VERSION}" 
  elif [[ "$ID" == "ubuntu" && $(echo "${VERSION_ID}" | cut -d '.' -f1) -ge 16 ]]; then
     log "当前系统为 Ubuntu ${VERSION_ID} ${UBUNTU_CODENAME}"
  else
     echo -e "${ERROR} 当前系统为 ${ID} ${VERSION_ID},不在支持的系统列表内!"
     exit 1
  fi

  # 检查依赖
  check_dependencies
  log "环境检查通过,开始安装"
}

# 安装依赖
check_dependencies() {
  source '/etc/os-release'

  if [[ "$ID" == "centos" ]]; then
     yum install wget git -y
  else
     apt install wget git -y
  fi

  if ! command -v wget &> /dev/null; then
    echo -e "${ERROR} wget 未安装!"
    exit 1
  fi

  if ! command -v git &> /dev/null; then
    echo -e "${ERROR} git 未安装!"
    exit 1
  fi  
}

# 打印信息
print_info() {
  VMESS="vmess://$(base64 -w 0 ${CONFIG_FILE})"
  QRCODE="https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=${VMESS}"

  echo -e "${INFO} V2Ray 配置信息: "
  echo -e "地址: $(grep \"'add'\" ${CONFIG_FILE} | awk -F \" '{print $4}')"
  echo -e "端口: $(grep \"'port'\" ${CONFIG_FILE} | awk -F \" '{print $4}')"  
  echo -e "用户ID: $(grep \"'id'\" ${CONFIG_FILE} | awk -F \" '{print $4}')"
  echo -e "额外ID: $(grep \"'alterId'\" ${CONFIG_FILE} | awk -F \" '{print $4}')"
  echo -e "传输协议: $(grep \"'net'\" ${CONFIG_FILE} | awk -F \" '{print $4}')" 
  echo -e "伪装类型: $(grep \"'type'\" ${CONFIG_FILE} | awk -F \" '{print $4}')"  
  echo -e "伪装域名: $(grep \"Host\" ${NGINX_CONF_FILE} | awk -F \" '{print $4}')"
  echo -e "WS 路径: $(grep \"path\" ${CONFIG_FILE} | awk -F \" '{print $4}')"

  echo -e "${INFO} V2Ray 客户端配置链接: "
  echo -e "${VMESS}"

  echo -e "${INFO} V2Ray 配置二维码: "
  echo -e "${QRCODE}"

  echo "${VMESS}" > ${INFO_FILE}
  echo "${QRCODE}" >> ${INFO_FILE}

  echo -e "${SUCCESS} V2Ray 配置信息已保存到 ${INFO_FILE}"
}

# 安装 Nginx
install_nginx() {
  if [[ -d "${NGINX_INSTALL_DIR}" ]]; then
    echo -e "${INFO} Nginx已存在,跳过编译安装过程。"
  else
    wget -O nginx.tar.gz http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
    tar -zxvf nginx.tar.gz

    cd nginx-${NGINX_VERSION}

    ./configure --prefix=${NGINX_INSTALL_DIR}
    make && make install

    cd .. && rm -rf nginx.tar.gz nginx-${NGINX_VERSION}    

    echo -e "${SUCCESS} Nginx 编译安装成功!"
  fi  
}

# 安装 V2Ray
install_v2ray() {
  mkdir -p ${INSTALL_DIR}/etc/v2ray
  wget https://github.com/v2fly/v2ray-core/releases/download/v${V2RAY_VERSION}/v2ray-linux-64.zip
  unzip v2ray-linux-64.zip -d ${INSTALL_DIR}
  rm -f v2ray-linux-64.zip

  echo -e "${SUCCESS} V2Ray 安装成功!"
}

# 配置 Nginx
config_nginx() {
  cat > ${NGINX_CONF_FILE} << EOF
server {
  listen 80;
  listen 443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate       /etc/v2ray/v2ray.crt; 
  ssl_certificate_key   /etc/v2ray/v2ray.key;

  location / {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:${V2PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
  }
}
EOF

  echo -e "${SUCCESS} Nginx 配置成功!"

  systemctl restart nginx
  systemctl enable nginx

}  

# 配置 V2Ray
config_v2ray() {
  UUID=$(cat /proc/sys/kernel/random/uuid)

  cat > ${CONFIG_FILE} << EOF  
{
  "inbounds": [
    {
      "port": ${V2PORT},
      "protocol": "vmess", 
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": ${ALTERID}
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WSPATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

  echo -e "${SUCCESS} V2Ray 配置成功!"

  systemctl restart v2ray
  systemctl enable v2ray
}

# 更新证书
update_cert() {
  systemctl stop nginx
  systemctl stop v2ray
  ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone -k ec-256 --force
  ~/.acme.sh/acme.sh --installcert -d ${DOMAIN} --fullchainpath /etc/v2ray/v2ray.crt --keypath /etc/v2ray/v2ray.key --ecc
  systemctl start nginx
  systemctl start v2ray
  echo -e "${SUCCESS} 证书更新成功!"
}

# 初始化
init_install() {
  # 参数校验
  if [ $# != 3 ]; then
    echo -e "${ERROR} 请输入正确的参数!"
    echo -e "${USAGE} bash $0 <域名> <Nginx监听端口> <V2Ray端口>"
    exit 1
  fi

  DOMAIN=$1
  NGINX_PORT=$2  
  V2PORT=$3

  WSPATH="/$(head -c 16 /dev/urandom | md5sum | head -c 8)"

  ALTERID=2

  # 安装前准备
  check_env

  # 安装 Nginx
  install_nginx

  # 安装 V2Ray
  install_v2ray

  # 配置 Nginx  
  config_nginx

  # 配置 V2Ray
  config_v2ray

  # 打印信息
  print_info  

  echo -e "${SUCCESS} V2Ray 安装成功!"
}

# 更新 V2Ray
update_v2ray() {
  echo -e "${INFO} 正在更新 V2Ray ..."
  bash <(curl -L -s https://raw.githubusercontent.com/ltsyydswow/v2ray/main/vmess.sh)
  echo -e "${SUCCESS} V2Ray 更新成功!"
  systemctl restart v2ray
}

# 卸载
uninstall() {
  echo -e "${INFO} 正在卸载 ..."  
  systemctl stop nginx
  systemctl disable nginx
  systemctl stop v2ray
  systemctl disable v2ray
  rm -rf ${NGINX_INSTALL_DIR} ${INSTALL_DIR}
  echo -e "${SUCCESS} 卸载成功!"
}

# 菜单选择
menu() {
  echo -e "
 
  V2Ray 安装管理脚本
  

  ${INFO} 1. 安装
  ${INFO} 2. 更新 V2Ray
  ${INFO} 3. 更新 证书
  ${INFO} 4. 查看 配置信息
  ${INFO} 5. 卸载
  ${INFO} 6. 退出

请选择: "

  read -p "请输入选项 [1-6]: " choose

  case $choose in
  1)
    init_install $DOMAIN $NGINX_PORT $V2PORT
    ;;
  2)  
    update_v2ray
    ;;
  3)
    update_cert
    ;; 
  4)
    print_info
    ;;
  5)
    uninstall
    ;;
  6)
    exit 0
    ;;
  *)  
    echo -e "${ERROR} 请输入正确的选项!"
    exit 1
    ;;
  esac
}

# ==========函数定义结束=========  

# 脚本开始
menu
