name: Build DD-WRT K2P (Final Fix)

on:
  workflow_dispatch:
    inputs:
      revision:
        description: 'SVN Revision (Default: HEAD)'
        required: true
        default: 'HEAD'
      ssh:
        description: 'SSH Debug'
        required: false
        default: 'false'

jobs:
  build:
    # 1. 修改为 22.04 解决排队问题
    runs-on: ubuntu-22.04
    env:
      DEBIAN_FRONTEND: noninteractive
    
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Install Dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            unzip libtool-bin ccache curl cmake gperf gawk flex bison nano xxd \
            fakeroot kmod cpio bc zip git python3-docutils gettext gengetopt gtk-doc-tools \
            autoconf-archive automake autopoint meson texinfo build-essential help2man pkg-config \
            zlib1g-dev libgmp3-dev libmpc-dev libmpfr-dev libncurses5-dev libltdl-dev wget libc-dev-bin \
            subversion python2
          
          sudo update-alternatives --install /usr/bin/python python /usr/bin/python2 1

      - name: Download Toolchain
        run: |
          echo "Downloading toolchain..."
          wget -q https://github.com/tsl0922/DD-WRT/releases/download/toolchain/toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz
          tar zxf toolchain-mipsel_24kc_gcc-13.1.0_musl.tar.gz
          ls -d toolchain-* # 2. 修正了上面代码粘连的错误，独立分开了这个步骤
      - name: Checkout Source Code
        run: |
          echo "PROFILE=k2p" > .config
          
          # 3. 【关键修复】将 Makefile 中的8个空格强行转换为 Tab，解决报错
          sed -i 's/^        /\t/g' Makefile
          
          # 修复 SVN 交互问题
          sed -i 's/svn co/svn co --trust-server-cert --non-interactive/g' Makefile
          sed -i 's/svn up/svn up --trust-server-cert --non-interactive/g' Makefile
          
          echo "Checking out SVN revision: ${{ github.event.inputs.revision }}..."
          make checkout REVISION=${{ github.event.inputs.revision }}

      - name: Fix Source Code & LAN Bug
        run: |
          echo "=== 1. Prepare Patches ==="
          make prepare

          echo "=== 2. Fix Compile Errors ==="
          find . -name "mk-ca-bundle.pl" -exec sed -i 's/my \$opt_k = 0;/my \$opt_k = 1;/g' {} +
          find . -name "mk-ca-bundle.pl" -exec sed -i 's/\$curl -s -L/\$curl -k -s -L/g' {} +
          find . -name "gencode.c" -type f -delete
          find . -name "scanner.c" -type f -delete
          find . -name "Makefile" -exec sed -i 's/-Werror//g' {} +

          echo "=== 3. Fix K2P LAN/VLAN ==="
          DEFAULTS_FILE=$(find dd-wrt -name "defaults.c" | grep "services/sysinit")
          
          if [ -f "$DEFAULTS_FILE" ]; then
            echo "Applying MT7621 VLAN Fix to $DEFAULTS_FILE..."
            sed -i 's/vlan1ports="0 1 2 3 5t"/vlan1ports="0 1 2 3 6t"/g' "$DEFAULTS_FILE"
            sed -i 's/vlan1ports="1 2 3 4 5t"/vlan1ports="0 1 2 3 6t"/g' "$DEFAULTS_FILE"
            sed -i 's/vlan2ports="4 5t"/vlan2ports="4 6t"/g' "$DEFAULTS_FILE"
            sed -i 's/vlan2ports="0 5t"/vlan2ports="4 6t"/g' "$DEFAULTS_FILE"
            grep -C 2 "vlan1ports" "$DEFAULTS_FILE" | head -n 10
          else
            echo "Error: defaults.c not found!"
            exit 1
          fi

      - name: Configure and Build
        run: |
          make configure
          make all

      - name: Organize Artifacts
        run: |
          mkdir -p firmware
          find images -name "*.bin" -exec cp {} firmware/ \;
          ls -lh firmware/

      - name: Upload Firmware
        uses: actions/upload-artifact@v4
        with:
          name: DD-WRT-K2P-Firmware
          path: firmware/
