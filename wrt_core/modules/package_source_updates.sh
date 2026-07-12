#!/usr/bin/env bash
# install_feeds 前的软件包源码替换与补齐。

update_golang() {
    if [[ -d ./feeds/packages/lang/golang ]]; then
        echo "正在更新 golang 软件包..."
        \rm -rf ./feeds/packages/lang/golang
        if ! git_retry clone --depth 1 -b "$GOLANG_BRANCH" "$GOLANG_REPO" ./feeds/packages/lang/golang; then
            echo "错误：克隆 golang 仓库 $GOLANG_REPO 失败" >&2
            exit 1
        fi
    fi
}


check_default_settings() {
    local settings_dir="$BUILD_DIR/package/emortal/default-settings"
    if [ -z "$(find "$BUILD_DIR/package" -type d -name "default-settings" -print -quit 2>/dev/null)" ]; then
        echo "在 $BUILD_DIR/package 中未找到 default-settings 目录，正在从 immortalwrt 仓库克隆..."
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if git_retry clone --depth 1 --filter=blob:none --sparse https://github.com/immortalwrt/immortalwrt.git "$tmp_dir"; then
            pushd "$tmp_dir" >/dev/null
            git_retry sparse-checkout set package/emortal/default-settings
            mkdir -p "$(dirname "$settings_dir")"
            mv package/emortal/default-settings "$settings_dir"
            popd >/dev/null
            rm -rf "$tmp_dir"
            echo "default-settings 克隆并移动成功。"
        else
            echo "错误：克隆 immortalwrt 仓库失败" >&2
            rm -rf "$tmp_dir"
            exit 1
        fi
    fi
}


add_ax6600_led() {
    local athena_led_dir="$BUILD_DIR/package/emortal/luci-app-athena-led"
    local repo_url="https://github.com/NONGFAH/luci-app-athena-led.git"

    echo "正在添加 luci-app-athena-led..."
    rm -rf "$athena_led_dir" 2>/dev/null

    if ! git_retry clone --depth=1 "$repo_url" "$athena_led_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-athena-led 仓库失败" >&2
        exit 1
    fi

    if [ -d "$athena_led_dir" ]; then
        chmod +x "$athena_led_dir/root/usr/sbin/athena-led"
        chmod +x "$athena_led_dir/root/etc/init.d/athena_led"
    else
        echo "错误：克隆操作后未找到目录 $athena_led_dir" >&2
        exit 1
    fi
}

add_nf_deaf() {
    local nfdeaf_dir="$BUILD_DIR/package/kernel/nf_deaf"
    local repo_url="https://github.com/kob/nf_deaf-openwrt.git"

    echo "正在添加 nf_deaf..."
    rm -rf "$nfdeaf_dir" 2>/dev/null

    if ! git clone --depth=1 "$repo_url" "$nfdeaf_dir"; then
        echo "错误：从 $repo_url 克隆 nfdeaf 仓库失败" >&2
        exit 1
    fi

    # 对刚刚下载的 Makefile 进行自动化修改
    local makefile="$nfdeaf_dir/Makefile"
    if [ -f "$makefile" ]; then
        echo "正在修改 Makefile..."
        sed -i '/^PKG_SOURCE_DATE/d' "$makefile"
        sed -i 's/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=master/' "$makefile"
        echo "nf_deaf Makefile 修改完成！"
    else
        echo "警告：未找到 $makefile" >&2
    fi
}

update_tailscale() {
    # 处理 UPX 压缩工具依赖
    echo "正在检查并配置 UPX 压缩工具依赖..."
    local upx_dir="$BUILD_DIR/upx"
    local upx_path="$upx_dir/upx"

    if [ ! -x "$upx_path" ]; then
        mkdir -p "$upx_dir"
        
        # 检查系统全局是否已经安装了 upx
        if ! command -v upx &> /dev/null; then
            echo "系统未安装 upx, 正在尝试通过 apt-get 自动安装..."
            # 这里的 || true 是为了防止网络卡顿时 update 报错导致整个脚本退出
            sudo apt-get update -y || true
            sudo apt-get install -y upx-ucl
        fi
        
        # 找到系统 upx 的绝对路径，并建立 Makefile 需要的软链接
        local sys_upx=$(command -v upx)
        if [ -n "$sys_upx" ]; then
            ln -sf "$sys_upx" "$upx_path"
            echo "✔ 成功创建 UPX 软链接: $sys_upx -> $upx_path"
        else
            echo "❌ 警告: UPX 安装失败或未找到，稍后的编译可能仍然会报错！" >&2
        fi
    else
        echo "✔ UPX 工具已就绪 ($upx_path)"
    fi

    # 使用GuNanOvO/openwrt-tailscale的tailscale 
    local repo_url="https://github.com/GuNanOvO/openwrt-tailscale.git"
    # tailscale 路径
    local target_dir="$BUILD_DIR/package/tailscale" 
    # 源码在大仓库里的实际相对路径
    local sub_dir="package/tailscale"
    # 设置一个临时克隆目录
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # 1. 如果存在旧的，先删掉
    if [ -d "$target_dir" ]; then
        echo "正在从 $target_dir 删除旧的 tailscale..."
        rm -rf "$target_dir"
    fi

    echo "正在使用稀疏克隆(sparse-checkout)拉取最新版 tailscale..."
    
    # 初始化并拉取仓库的骨架（不下载具体文件，极速）
    rm -rf "$tmp_dir"
    if ! git clone --depth 1 --filter=blob:none --sparse "$repo_url" "$tmp_dir"; then
        echo "错误：从 $repo_url 拉取仓库骨架失败" >&2
        exit 1
    fi

    # 告诉 Git 我们只需要 package/tailscale 这一个文件夹
    git -C "$tmp_dir" sparse-checkout set "$sub_dir"

    # 将下载好的子文件夹移动到我们真正需要的目标路径
    mv "$tmp_dir/$sub_dir" "$target_dir"
    # 修改 Makefile（删除包含 /builder 的行）
    if ! sed -i '/\/builder/d' "$target_dir/Makefile"; then
        echo "错误：修改 Makefile 失败" >&2
        exit 1
    fi
    # 清除临时文件夹的残留
    rm -rf "$tmp_dir"
    
    echo "tailscale 更新完成！"
}

add_podman() {
    local podman_dir="$BUILD_DIR/package/luci-app-podman"
    local repo_url="https://github.com/Zerogiven-OpenWRT-Packages/luci-app-podman.git"
    rm -rf "$podman_dir" 2>/dev/null
    echo "正在添加 luci-app-podman..."
    if ! git clone --depth 1 "$repo_url" "$podman_dir"; then
        echo "错误：从 $repo_url 克隆 openwrt-podman 仓库失败" >&2
        exit 1
    fi
}

add_dufs() {
    local dufs_dir="$BUILD_DIR/package/luci-app-dufs"
    local repo_url="https://github.com/zouzonghao/luci-app-dufs.git"
    rm -rf "$dufs_dir" 2>/dev/null
    echo "正在添加 luci-app-dufs..."
    if ! git clone --depth 1 "$repo_url" "$dufs_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-dufs 仓库失败" >&2
        exit 1
    fi
}

add_qbittorrentstatic() {
    local qbittorrentstatic_dir="$BUILD_DIR/package/luci-app-qbittorrent-static"
    local repo_url="https://github.com/haohaoget/luci-app-qbittorrent-static.git"
    rm -rf "$qbittorrentstatic_dir" 2>/dev/null
    echo "正在添加 luci-app-qbittorrent-static..."
    if ! git clone --depth 1 "$repo_url" "$qbittorrentstatic_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-qbittorrent-static 仓库失败" >&2
        exit 1
    fi
}

add_timecontrol() {
    local timecontrol_dir="$BUILD_DIR/package/luci-app-timecontrol"
    local repo_url="https://github.com/sirpdboy/luci-app-timecontrol.git"
    rm -rf "$timecontrol_dir" 2>/dev/null
    echo "正在添加 luci-app-timecontrol..."
    if ! git_retry clone --depth 1 "$repo_url" "$timecontrol_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-timecontrol 仓库失败" >&2
        exit 1
    fi
}


update_smartdns() {
    local SMARTDNS_REPO="https://github.com/ZqinKing/openwrt-smartdns.git"
    local SMARTDNS_DIR="$BUILD_DIR/feeds/packages/net/smartdns"
    local LUCI_APP_SMARTDNS_REPO="https://github.com/pymumu/luci-app-smartdns.git"
    local LUCI_APP_SMARTDNS_DIR="$BUILD_DIR/feeds/luci/applications/luci-app-smartdns"

    echo "正在更新 smartdns..."
    rm -rf "$SMARTDNS_DIR"
    if ! git_retry clone --depth=1 "$SMARTDNS_REPO" "$SMARTDNS_DIR"; then
        echo "错误：从 $SMARTDNS_REPO 克隆 smartdns 仓库失败" >&2
        exit 1
    fi

    install -Dm644 "$BASE_PATH/patches/100-smartdns-optimize.patch" "$SMARTDNS_DIR/patches/100-smartdns-optimize.patch"
    sed -i '/define Build\/Compile\/smartdns-ui/,/endef/s/CC=\$(TARGET_CC)/CC="\$(TARGET_CC_NOCACHE)"/' "$SMARTDNS_DIR/Makefile"

    echo "正在更新 luci-app-smartdns..."
    rm -rf "$LUCI_APP_SMARTDNS_DIR"
    if ! git_retry clone --depth=1 "$LUCI_APP_SMARTDNS_REPO" "$LUCI_APP_SMARTDNS_DIR"; then
        echo "错误：从 $LUCI_APP_SMARTDNS_REPO 克隆 luci-app-smartdns 仓库失败" >&2
        exit 1
    fi
}


update_mwan3_fw4() {
    local mwan3_repo="https://github.com/dl12345/mwan3.git"
    local luci_app_mwan3_repo="https://github.com/dl12345/luci-app-mwan3.git"
    local mwan3_branch="openwrt-25.12"
    local mwan3_dir="$BUILD_DIR/feeds/packages/net/mwan3"
    local luci_app_mwan3_dir="$BUILD_DIR/feeds/luci/applications/luci-app-mwan3"

    echo "正在更新 mwan3 fw4 适配版本..."
    mkdir -p "$(dirname "$mwan3_dir")" "$(dirname "$luci_app_mwan3_dir")"
    rm -rf "$mwan3_dir" "$luci_app_mwan3_dir"

    if ! git_retry clone --depth 1 -b "$mwan3_branch" "$mwan3_repo" "$mwan3_dir"; then
        echo "错误：从 $mwan3_repo 克隆 mwan3 仓库失败" >&2
        exit 1
    fi

    echo "正在更新 luci-app-mwan3 fw4 适配版本..."
    if ! git_retry clone --depth 1 -b "$mwan3_branch" "$luci_app_mwan3_repo" "$luci_app_mwan3_dir"; then
        echo "错误：从 $luci_app_mwan3_repo 克隆 luci-app-mwan3 仓库失败" >&2
        exit 1
    fi
}


update_diskman() {
    local path="$BUILD_DIR/feeds/luci/applications/luci-app-diskman"
    local repo_url="https://github.com/lisaac/luci-app-diskman.git"
    if [ -d "$path" ]; then
        echo "正在更新 diskman..."
        cd "$BUILD_DIR/feeds/luci/applications" || return
        \rm -rf "luci-app-diskman"

        if ! git_retry clone --filter=blob:none --no-checkout "$repo_url" diskman; then
            echo "错误：从 $repo_url 克隆 diskman 仓库失败" >&2
            exit 1
        fi
        cd diskman || return

        git_retry sparse-checkout init --cone
        git_retry sparse-checkout set applications/luci-app-diskman || return

        git_retry checkout --quiet

        mv applications/luci-app-diskman ../luci-app-diskman || return
        cd .. || return
        \rm -rf diskman
        cd "$BUILD_DIR"

        sed -i 's/fs-ntfs /fs-ntfs3 /g' "$path/Makefile"
        sed -i '/ntfs-3g-utils /d' "$path/Makefile"
    fi
}


_sync_luci_lib_docker() {
    local lib_path="$BUILD_DIR/feeds/luci/libs/luci-lib-docker"
    local repo_url="https://github.com/lisaac/luci-lib-docker.git"

    if [ ! -d "$lib_path" ]; then
        echo "正在同步 luci-lib-docker..."
        mkdir -p "$BUILD_DIR/feeds/luci/libs" || return
        cd "$BUILD_DIR/feeds/luci/libs" || return

        if ! git_retry clone --filter=blob:none --no-checkout "$repo_url" luci-lib-docker-tmp; then
            echo "错误：从 $repo_url 克隆 luci-lib-docker 仓库失败" >&2
            exit 1
        fi
        cd luci-lib-docker-tmp || return

        git_retry sparse-checkout init --cone
        git_retry sparse-checkout set collections/luci-lib-docker || return

        git_retry checkout --quiet

        mv collections/luci-lib-docker ../luci-lib-docker || return
        cd .. || return
        # 处理 luci-lib-docker 版本号中的 'v' 前缀
        if [ -f "$BUILD_DIR/feeds/luci/libs/luci-lib-docker/Makefile" ]; then
            sed -i 's/PKG_VERSION:=v/PKG_VERSION:=/g' "$BUILD_DIR/feeds/luci/libs/luci-lib-docker/Makefile"
        fi
        \rm -rf luci-lib-docker-tmp
        cd "$BUILD_DIR"
        echo "luci-lib-docker 同步完成"
    fi
}


update_dockerman() {
    local path="$BUILD_DIR/feeds/luci/applications/luci-app-dockerman"
    local repo_url="https://github.com/lisaac/luci-app-dockerman.git"

    if [ -d "$path" ]; then
        echo "正在更新 dockerman..."
        _sync_luci_lib_docker || return

        cd "$BUILD_DIR/feeds/luci/applications" || return
        \rm -rf "luci-app-dockerman"

        if ! git_retry clone --filter=blob:none --no-checkout "$repo_url" dockerman; then
            echo "错误：从 $repo_url 克隆 dockerman 仓库失败" >&2
            exit 1
        fi
        cd dockerman || return

        git_retry sparse-checkout init --cone
        git_retry sparse-checkout set applications/luci-app-dockerman || return

        git_retry checkout --quiet

        mv applications/luci-app-dockerman ../luci-app-dockerman || return
        cd .. || return
        \rm -rf dockerman
        cd "$BUILD_DIR"

        if declare -F docker_stack_sync_dockerman_nftables_compat >/dev/null 2>&1; then
            docker_stack_sync_dockerman_nftables_compat "$BUILD_DIR" "0" || return 1
        fi

        # 处理 dockerman 版本号中的 'v' 前缀
        if [ -f "$path/Makefile" ]; then
            sed -i 's/PKG_VERSION:=v/PKG_VERSION:=/g' "$path/Makefile"
        fi

        echo "dockerman 更新完成"
    fi
}


add_quickfile() {
    local repo_url="https://github.com/sbwml/luci-app-quickfile.git"
    local target_dir="$BUILD_DIR/package/emortal/quickfile"
    if [ -d "$target_dir" ]; then
        rm -rf "$target_dir"
    fi
    echo "正在添加 luci-app-quickfile..."
    if ! git_retry clone --depth 1 "$repo_url" "$target_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-quickfile 仓库失败" >&2
        exit 1
    fi

    local makefile_path="$target_dir/quickfile/Makefile"
    if [ -f "$makefile_path" ]; then
        sed -i '/\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-\$(ARCH_PACKAGES)/c\
\tif [ "\$(ARCH_PACKAGES)" = "x86_64" ]; then \\\
\t\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-x86_64 \$(1)\/usr\/bin\/quickfile; \\\
\telse \\\
\t\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-aarch64_generic \$(1)\/usr\/bin\/quickfile; \\\
\tfi' "$makefile_path"
    fi
}


update_argon() {
    local repo_url="https://github.com/ZqinKing/luci-theme-argon.git"
    local dst_theme_path="$BUILD_DIR/feeds/luci/themes/luci-theme-argon"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "正在更新 argon 主题..."

    if ! git_retry clone --depth 1 "$repo_url" "$tmp_dir"; then
        echo "错误：从 $repo_url 克隆 argon 主题仓库失败" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$dst_theme_path"
    rm -rf "$tmp_dir/.git"
    mv "$tmp_dir" "$dst_theme_path"

    echo "luci-theme-argon 更新完成"
    # 修改主题背景
    if [ -d "$dst_theme_path" ]; then
      cp -f $BASE_PATH/argon/img/bg1.jpg $dst_theme_path/htdocs/luci-static/argon/img/bg1.jpg
      cp -f $BASE_PATH/argon/img/argon.svg $dst_theme_path/htdocs/luci-static/argon/img/argon.svg
      cp -f $BASE_PATH/argon/favicon.ico $dst_theme_path/htdocs/luci-static/argon/favicon.ico
      cp -f $BASE_PATH/argon/icon/android-icon-192x192.png $dst_theme_path/htdocs/luci-static/argon/icon/android-icon-192x192.png
      cp -f $BASE_PATH/argon/icon/apple-icon-144x144.png $dst_theme_path/htdocs/luci-static/argon/icon/apple-icon-144x144.png
      cp -f $BASE_PATH/argon/icon/apple-icon-60x60.png $dst_theme_path/htdocs/luci-static/argon/icon/apple-icon-60x60.png
      cp -f $BASE_PATH/argon/icon/apple-icon-72x72.png $dst_theme_path/htdocs/luci-static/argon/icon/apple-icon-72x72.png
      cp -f $BASE_PATH/argon/icon/favicon-16x16.png $dst_theme_path/htdocs/luci-static/argon/icon/favicon-16x16.png
      cp -f $BASE_PATH/argon/icon/favicon-32x32.png $dst_theme_path/htdocs/luci-static/argon/icon/favicon-32x32.png
      cp -f $BASE_PATH/argon/icon/favicon-96x96.png $dst_theme_path/htdocs/luci-static/argon/icon/favicon-96x96.png
      cp -f $BASE_PATH/argon/icon/ms-icon-144x144.png $dst_theme_path/htdocs/luci-static/argon/icon/ms-icon-144x144.png
      echo "完成feeds/luci/themes/luci-theme-argon修改主题背景"
    fi
}


update_package() {
    # 根据上游版本信息刷新包版本与哈希。
    local dir=$(find "$BUILD_DIR/package" \( -type d -o -type l \) -name "$1")
    if [ -z "$dir" ]; then
        return 0
    fi
    local branch="$2"
    if [ -z "$branch" ]; then
        branch="releases"
    fi
    local mk_path="$dir/Makefile"
    if [ -f "$mk_path" ]; then
        local PKG_REPO=$(grep -oE "^PKG_GIT_URL.*github.com(/[-_a-zA-Z0-9]{1,}){2}" "$mk_path" | awk -F"/" '{print $(NF - 1) "/" $NF}')
        if [ -z "$PKG_REPO" ]; then
            PKG_REPO=$(grep -oE "^PKG_SOURCE_URL.*github.com(/[-_a-zA-Z0-9]{1,}){2}" "$mk_path" | awk -F"/" '{print $(NF - 1) "/" $NF}')
            if [ -z "$PKG_REPO" ]; then
                echo "错误：无法从 $mk_path 提取 PKG_REPO" >&2
                return 1
            fi
        fi
        local PKG_VER
        if ! PKG_VER=$(curl_retry -fsSL "https://api.github.com/repos/$PKG_REPO/$branch" | jq -r '.[0] | .tag_name // .name'); then
            echo "错误：从 https://api.github.com/repos/$PKG_REPO/$branch 获取版本信息失败" >&2
            return 1
        fi
        if [ -n "$3" ]; then
            PKG_VER="$3"
        fi
        local PKG_VER_CLEAN
        PKG_VER_CLEAN=$(echo "$PKG_VER" | sed 's/^v//')
        if grep -q "^PKG_GIT_SHORT_COMMIT:=" "$mk_path"; then
            local PKG_GIT_URL_RAW
            PKG_GIT_URL_RAW=$(awk -F"=" '/^PKG_GIT_URL:=/ {print $NF}' "$mk_path")
            local PKG_GIT_REF_RAW
            PKG_GIT_REF_RAW=$(awk -F"=" '/^PKG_GIT_REF:=/ {print $NF}' "$mk_path")

            if [ -z "$PKG_GIT_URL_RAW" ] || [ -z "$PKG_GIT_REF_RAW" ]; then
                echo "错误：$mk_path 缺少 PKG_GIT_URL 或 PKG_GIT_REF，无法更新 PKG_GIT_SHORT_COMMIT" >&2
                return 1
            fi

            local PKG_GIT_REF_RESOLVED
            PKG_GIT_REF_RESOLVED=$(echo "$PKG_GIT_REF_RAW" | sed "s/\$(PKG_VERSION)/$PKG_VER_CLEAN/g; s/\${PKG_VERSION}/$PKG_VER_CLEAN/g")

            local PKG_GIT_REF_TAG="${PKG_GIT_REF_RESOLVED#refs/tags/}"

            local COMMIT_SHA
            local LS_REMOTE_OUTPUT
            LS_REMOTE_OUTPUT=$(git_retry ls-remote "https://$PKG_GIT_URL_RAW" "refs/tags/${PKG_GIT_REF_TAG}" "refs/tags/${PKG_GIT_REF_TAG}^{}" 2>/dev/null)
            COMMIT_SHA=$(echo "$LS_REMOTE_OUTPUT" | awk '/\^\{\}$/ {print $1; exit}')
            if [ -z "$COMMIT_SHA" ]; then
                COMMIT_SHA=$(echo "$LS_REMOTE_OUTPUT" | awk 'NR==1{print $1}')
            fi
            if [ -z "$COMMIT_SHA" ]; then
                COMMIT_SHA=$(git_retry ls-remote "https://$PKG_GIT_URL_RAW" "${PKG_GIT_REF_RESOLVED}^{}" 2>/dev/null | awk 'NR==1{print $1}')
            fi
            if [ -z "$COMMIT_SHA" ]; then
                COMMIT_SHA=$(git_retry ls-remote "https://$PKG_GIT_URL_RAW" "$PKG_GIT_REF_RESOLVED" 2>/dev/null | awk 'NR==1{print $1}')
            fi
            if [ -z "$COMMIT_SHA" ]; then
                echo "错误：无法从 https://$PKG_GIT_URL_RAW 获取 $PKG_GIT_REF_RESOLVED 的提交哈希" >&2
                return 1
            fi

            local SHORT_COMMIT
            SHORT_COMMIT=$(echo "$COMMIT_SHA" | cut -c1-7)
            sed -i "s/^PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$SHORT_COMMIT/g" "$mk_path"
        fi
        PKG_VER=$(echo "$PKG_VER" | grep -oE "[\.0-9]{1,}")

        local PKG_NAME=$(awk -F"=" '/PKG_NAME:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\?\.a-zA-Z0-9]{1,}")
        local PKG_SOURCE=$(awk -F"=" '/PKG_SOURCE:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\?\.a-zA-Z0-9]{1,}")
        local PKG_SOURCE_URL=$(awk -F"=" '/PKG_SOURCE_URL:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\{\}\?\.a-zA-Z0-9]{1,}")
        local PKG_GIT_URL=$(awk -F"=" '/PKG_GIT_URL:=/ {print $NF}' "$mk_path")
        local PKG_GIT_REF=$(awk -F"=" '/PKG_GIT_REF:=/ {print $NF}' "$mk_path")

        PKG_SOURCE_URL=${PKG_SOURCE_URL//\$\(PKG_GIT_URL\)/$PKG_GIT_URL}
        PKG_SOURCE_URL=${PKG_SOURCE_URL//\$\(PKG_GIT_REF\)/$PKG_GIT_REF}
        PKG_SOURCE_URL=${PKG_SOURCE_URL//\$\(PKG_NAME\)/$PKG_NAME}
        PKG_SOURCE_URL=$(echo "$PKG_SOURCE_URL" | sed "s/\${PKG_VERSION}/$PKG_VER/g; s/\$(PKG_VERSION)/$PKG_VER/g")
        PKG_SOURCE=${PKG_SOURCE//\$\(PKG_NAME\)/$PKG_NAME}
        PKG_SOURCE=${PKG_SOURCE//\$\(PKG_VERSION\)/$PKG_VER}

        local PKG_HASH
        if ! PKG_HASH=$(curl_retry -fsSL "$PKG_SOURCE_URL""$PKG_SOURCE" | sha256sum | cut -b -64); then
            echo "错误：从 $PKG_SOURCE_URL$PKG_SOURCE 获取软件包哈希失败" >&2
            return 1
        fi

        sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:='$PKG_VER'/g' "$mk_path"
        sed -i 's/^PKG_HASH:=.*/PKG_HASH:='$PKG_HASH'/g' "$mk_path"

        echo "更新软件包 $1 到 $PKG_VER $PKG_HASH"
    fi
}
