name: Build DD-WRT K2P (Fixed)

on:
  workflow_dispatch:
    inputs:
      revision:
        description: 'SVN Revision (保持默认即为最新)'
        required: true
        default: 'HEAD'
      ssh:
        description: 'SSH Debug (开启后可远程登录调试)'
        required: false
        default: 'false'

jobs:
  build:
    runs-on: ubuntu-20.04
    env:
      DEBIAN_FRONTEND: noninteractive
    
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Install Dependencies
        run: |
          sudo apt-get update
          # 安装编译所需的依赖，特别是 python2 (旧版构建脚本必须)
          sudo apt-get install -y \
            unzip libtool-bin ccache curl cmake gperf gawk flex bison nano xxd \
            fakeroot kmod cpio bc zip git python3-docutils gettext gengetopt gtk-doc-tools \
            autoconf-archive automake autopoint meson texinfo build-essential help2man pkg-config \
            zlib1g-dev libgmp3-dev libmpc-dev libmpfr-dev libncurses5-dev libltdl-dev wget libc-dev-bin \
            subversion python2
          
          # 设置 python2 为默认 python
          sudo update-alternatives --install /usr/bin/python python /usr/bin/python2 1

      - name: Download Toolchain
        run: |
          # 根据 Makefile 定义，下载对应的 musl 工具链
          # 您的 Makefile 指定路径是: $(TOP_DIR)/toolchain-mipsel_24kc_gcc-13.1.0_musl
          echo "Downloading toolchain..."
          wget -q https://github.com/tsl0922/DD-WRT/releases/download/toolchain/toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz
          tar zxf toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz
          ls -d toolchain-* - name: Checkout Source Code
        run: |
          # 生成配置文件 (K2P)
          echo "PROFILE=k2p" > .config
          
          # 修复 Makefile：添加 SVN 非交互参数，防止因证书询问卡死
          sed -i 's/svn co/svn co --trust-server-cert --non-interactive/g' Makefile
          sed -i 's/svn up/svn up --trust-server-cert --non-interactive/g' Makefile
          
          # 拉取源码
          echo "Checking out SVN revision: ${{ github.event.inputs.revision }}..."
          make checkout REVISION=${{ github.event.inputs.revision }}

      - name: Fix Source Code & LAN Bug
        run: |
          echo "=== 1. 预处理 (应用补丁) ==="
          # 必须先运行 make prepare，让仓库自带的 patches 先生效
          # 否则我们修改的代码会被补丁覆盖或导致冲突
          make prepare

          echo "=== 2. 修复编译报错 (Libpcap & Curl) ==="
          # 修复 mk-ca-bundle 脚本
          find . -name "mk-ca-bundle.pl" -exec sed -i 's/my \$opt_k = 0;/my \$opt_k = 1;/g' {} +
          find . -name "mk-ca-bundle.pl" -exec sed -i 's/\$curl -s -L/\$curl -k -s -L/g' {} +
          
          # 删除会冲突的 libpcap 生成文件，强迫重新生成
          find . -name "gencode.c" -type f -delete
          find . -name "scanner.c" -type f -delete
          
          # 移除 Makefile 中的 -Werror，防止小警告中断编译
          find . -name "Makefile" -exec sed -i 's/-Werror//g' {} +

          echo "=== 3. 修复 K2P LAN 口不通问题 (VLAN Fix) ==="
          # 目标文件：src/router/services/sysinit/defaults.c
          # 该路径由您的 Makefile gen_patches 部分确认
          DEFAULTS_FILE=$(find dd-wrt -name "defaults.c" | grep "services/sysinit")
          
          if [ -f "$DEFAULTS_FILE" ]; then
            echo "Found defaults.c at $DEFAULTS_FILE"
            echo "Applying MT7621 VLAN Fix..."
            
            # 【核心修复】
            # 这里的原理是将错误的端口定义替换为正确的。
            # 很多旧源码把 CPU 端口写成 5t，但新内核下 K2P (MT7621) 必须是 6t
            
            # 1. 修复 VLAN1 (LAN) -> 对应端口 0 1 2 3 和 CPU(6t)
            sed -i 's/vlan1ports="0 1 2 3 5t"/vlan1ports="0 1 2 3 6t"/g' "$DEFAULTS_FILE"
            sed -i 's/vlan1ports="1 2 3 4 5t"/vlan1ports="0 1 2 3 6t"/g' "$DEFAULTS_FILE"
            
            # 2. 修复 VLAN2 (WAN) -> 对应端口 4 和 CPU(6t)
            sed -i 's/vlan2ports="4 5t"/vlan2ports="4 6t"/g' "$DEFAULTS_FILE"
            sed -i 's/vlan2ports="0 5t"/vlan2ports="4 6t"/g' "$DEFAULTS_FILE"
            
            # 检查修复结果
            echo "Verify changes in defaults.c:"
            grep -C 2 "vlan1ports" "$DEFAULTS_FILE" | head -n 10
          else
            echo "Error: defaults.c not found! Build might fail."
            exit 1
          fi

      - name: Configure and Build
        run: |
          echo "Starting Configure..."
          make configure
          
          echo "Starting Build..."
          make all

      - name: Organize Artifacts
        run: |
          mkdir -p firmware
          # 查找生成的 .bin 文件
          find images -name "*.bin" -exec cp {} firmware/ \;
          ls -lh firmware/

      - name: Upload Firmware
        uses: actions/upload-artifact@v4
        with:
          name: DD-WRT-K2P-Firmware
          path: firmware/
      
      - name: SSH connection to Actions
        uses: P3TERX/ssh2actions@v1.0.0
        if: (github.event.inputs.ssh == 'true') || contains(github.event.action, 'ssh')
        env:
         TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
         TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
