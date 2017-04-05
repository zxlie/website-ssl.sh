#!/bin/sh

# ******************************************
# author: Alien(https://www.baidufe.com)
# github: https://github.com/zxlie
# ******************************************

printf "\n\n`date`> 升级Https证书\n"

# 必须 root 账户运行
if [ $(whoami) != 'root' ];then
    echo `date "+%Y/%m/%d %H:%M:%S> "` "必须用 root 账户执行此脚本！"
    exit
fi

# 当前工具的版本号
tool_version="2.2"

# 系统openssl.cnf文件的位置（可以不用管）
openssl_cnf="/etc/ssl/openssl.cnf"

# 安装配置文件
function install_config(){
    cat > libs/wsl.cnf.sh <<EOF
#!/bin/sh

# ************************ 配置区域 START ******************************
# 你的ssl主目录位置
ssl_dir="/home/work/www/ssl"
# nginx中配置的，给 Let's Encrypt 验证用的
challenges_dir="/home/work/www/challenges/"
# 按照你的需求进行配置，多个域名用空格分开
websites="your-website.com www.your-website.com"
# ************************ 配置区域 END ********************************
EOF
}

# 检查配置文件是否已配置
function check_config(){
    if [[ ! -f libs/wsl.cnf.sh ]];then
        install_config
    fi

    # 载入配置文件
    source ./libs/wsl.cnf.sh

    if [[ ! -d $ssl_dir || ! -d $challenges_dir || -z $websites ]];then
        printf "\n您的配置文件「libs/wsl.cnf.sh」配置不正确或还未进行配置，请检查！\n\n"
        exit
    fi
}


# 初始化，准备一些必要的文件
function init(){

    cd $ssl_dir

    # 创建一个 RSA 私钥用于 Let's Encrypt 识别你的身份
    if [[ ! -f account.key ]];then
        openssl genrsa 4096 > account.key
    fi

    # 创建一个域名私钥
    if [[ ! -f domain.key ]];then
        openssl genrsa 4096 > domain.key
    fi

    # 检查openssl.cnf文件是否存在，不存在则下载一个过来
    if [[ ! -f $openssl_cnf ]];then
        cp libs/openssl.cnf /etc/ssl/
    fi
}

# 创建域名csr文件
function create_csr(){

    san_websites="\n[SAN]\nsubjectAltName="
    for i in $websites;do
        san_websites=$san_websites"DNS:"$i","
    done
    printf ${san_websites%,*} > ssl.cnf.tmp
    cat $openssl_cnf ssl.cnf.tmp > merged.cnf.tmp
    openssl req -new -sha256 -key domain.key -subj "/" -reqexts SAN -config merged.cnf.tmp > domain.csr
    rm -rf *.tmp
    echo "domain.csr文件创建成功！"
}

# 创建pem文件
function create_pem(){

    # 检查csr文件是否存在，不存在则根据配置重新生成一个
    if [[ ! -f domain.csr ]];then
        create_csr
    fi

    # 申请证书crt文件
    python libs/acme_tiny.py --account-key account.key --csr domain.csr --acme-dir $challenges_dir > signed.crt
    # 下载Let’s Encrypt 的中间证书
    curl -so lets-signed.pem https://letsencrypt.org/certs/lets-encrypt-x1-cross-signed.pem
    # 俩证书合并，得到最终pem文件
    cat signed.crt lets-signed.pem > ssl-encrypt.pem
    rm -rf signed.crt lets-signed.pem

    printf "\nssl-encrypt.pem文件创建成功！\n如果日志中出现错误，则pem文件并不可用，务必保证nginx conf文件已做如下配置：\n"
    cat <<EOF

    # CA认证
    location ^~ /.well-known/acme-challenge/ {
        root $challenges_dir;
        try_files $uri =404;
    }
EOF
}

# 自动更新证书文件
function auto_renew(){

    cd $ssl_dir

    # 做文件备份
    backup_dir="backup/"$(date +"%Y%m%d-%H%M%S")
    mkdir -p $backup_dir
    file_list=$(ls | grep "account.key\|domain.csr\|domain.key\|ssl-encrypt.pem")
    for f in $file_list;do
        mv $f $backup_dir
    done

    init && create_pem

    # 重启nginx
    /sbin/service nginx reload
    echo "ssl证书自动更新成功！Nginx已重启！"
}

# 获取一个nginx配置文件的demo
function nginx_tpl(){

    echo "Nginx conf配置模板已生成：nginx.demo.conf"

    cat > nginx.demo.conf <<EOF

    # 这只是一个Demo，请根据自己的实际需求调整nginx-conf
    server {
        listen       80;
        server_name  your-website.com;

        # CA认证
        location ^~ /.well-known/acme-challenge/ {
            root $challenges_dir;
            try_files $uri =404;
        }

        # 所有http的请求都转向https
        location / {
            rewrite ^/(.*)$ https://$http_host$uri permanent;
        }
    }

    server {
        listen 443 ssl;
        server_name  your-website.com;

        ssl_protocols TLSv1 TLSv1.1 TLSv1.2 SSLv2;
        ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
        ssl_prefer_server_ciphers on;
        ssl_certificate $ssl_dir/ssl-encrypt.pem;
        ssl_certificate_key $ssl_dir/domain.key;
        ssl_session_timeout 5m;
        ssl_session_cache shared:SSL:10m;

        index index.html;
        root /home/work/www;

        location / {
            expires 30d;
        }
        access_log  /tmp/your-website.access.log;
        error_log  /tmp/your-website.error.log;
    }
EOF
}

# crontab
function install_crontab(){
    printf "\n# Let’s Encrypt 签发的证书只有90天有效期，可以设置为每月1号自动更新\n"
    printf "0 0 1 * * cd $ssl_dir/ && sh website-ssl.sh renew >/dev/null 2>&1\n\n"
}

# 工具升级
function tool_upgrade(){
    curl -so website-ssl.new.sh https://github.com/zxlie/website-ssl.sh/blob/master/website-ssl.sh
    test_valid=$(grep -i -n "<!DOCTYPE html" website-ssl.new.sh | cut -d":" -f 1)
    if [[ -z $test_valid || $test_valid -gt 10 ]];then
        echo "工具已升级到最新版！"
        mv website-ssl.new.sh website-ssl.sh && chmod 0755 website-ssl.sh
        sh website-ssl.sh -v
    else
        rm -rf website-ssl.new.sh
        echo "工具升级失败，请稍后再试，或者到「Github」进行源码更新："
        echo "  https://github.com/zxlie/website-ssl.sh "
    fi
}

# 显示版本号
function show_version(){
    echo "当前版本号：v$tool_version"
}

# 使用帮助
function usage(){

    cat <<EOF

        网站ssl自动化工具（v$tool_version）使用方法:

        usage: sh $0 -v | csr | pem | nginx | renew | crontab | upgrade
        -v        查看工具的版本号
        csr       根据域名配置生成csr证书文件（For pem）
        pem       生成 Let's Encrypt 认可的pem证书文件
        nginx     获取nginx配置文件Demo
        renew     更新ssl证书文件
        crontab   自动更新pem证书文件的crontab任务
        upgrade   升级「website-ssl.sh」工具到最新版

EOF
        exit
}

# app启动程序
function app_start(){
    # 第一步，一定是先检查配置啦
    check_config

    case $1 in
        csr)
            init && create_csr && break
            ;;
        pem)
            init && create_pem && break
            ;;
        renew)
            auto_renew && break
            ;;
        nginx)
            nginx_tpl && break
            ;;
        crontab)
            install_crontab && break
            ;;
        upgrade)
            tool_upgrade && break
            ;;
        -v|version)
            show_version && break
            ;;
        *)
            usage
            break
            ;;
    esac
}

app_start $1