#!/bin/bash
id
df -h
free -h
cat /proc/cpuinfo

echo "update submodules"
# git submodule update --init --recursive --remote || { echo "submodule update failed"; exit 1; }
git submodule update --init --recursive || { echo "submodule init failed"; exit 1; }

if [ -d "immortalwrt" ]; then
    echo "repo dir exists"
    cd immortalwrt
    git pull || { echo "git pull failed"; exit 1; }
    git reset --hard HEAD
    git clean -fd
else
    echo "repo dir not exists"
    git clone -b openwrt-24.10  "https://github.com/immortalwrt/immortalwrt" || { echo "git clone failed"; exit 1; }
    cd immortalwrt
fi

echo "add feeds"
cat feeds.conf.default > feeds.conf
echo "" >> feeds.conf
echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf
echo "src-git istore https://github.com/linkease/istore;main" >> feeds.conf

echo "update files"
rm -rf files
cp -r ../files .

# Add TD-TECH option id patch
echo "add TD-TECH option id patch"
cp ../999-add-TD-TECH-option-id.patch ./target/linux/rockchip/patches-6.6/999-add-TD-TECH-option-id.patch
ls -lah ./target/linux/rockchip/patches-6.6/999-add-TD-TECH-option-id.patch

if [ -f "feeds/packages/lang/rust/Makefile" ]; then
   bash -c "cd feeds/packages && git checkout -- \"lang/rust/Makefile\""
fi

# Add xgp-v3-screen
if [ -d "package/xgp-v3-screen" ] || [ -L "package/xgp-v3-screen" ]; then
    echo "package/xgp-v3-screen exists, removing old version"
    rm -rf package/xgp-v3-screen
fi

git -C package clone --depth 1 https://github.com/junhong-l/xgp-v3-screen.git || { echo "git clone xgp-v3-screen failed"; exit 1; }

echo "xgp-v3-screen is ready"

echo "update feeds"
./scripts/feeds update -a || { echo "update feeds failed"; exit 1; }
echo "install feeds"
./scripts/feeds install -a || { echo "install feeds failed"; exit 1; }
./scripts/feeds install -a -f -p qmodem || { echo "install qmodem feeds failed"; exit 1; }

if [ -L "package/zz-packages" ]; then
    echo "package/zz-packages is already a symlink"
else
    if [ -d "package/zz-packages" ]; then
        echo "package/zz-packages directory exists, removing it"
        rm -rf package/zz-packages
    fi
    ln -s ../../zz-packages package/zz-packages
    echo "Created symlink package/zz-packages -> ../../zz-packages"
fi
