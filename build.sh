#!/bin/bash
#
# Compile script for QuicksilveR kernel
# Copyright (C) 2020-2023 Adithya R.

# Setup getopt.
long_opts="regen,clean,homedir:,tcdir:outdir:"
getopt_cmd=$(getopt -o rch:t:o: --long "$long_opts" \
            -n $(basename $0) -- "$@") || \
            { echo -e "\nError: Getopt failed. Extra args\n"; exit 1;}

eval set -- "$getopt_cmd"

while true; do
    case "$1" in
        -r|--regen|r|regen) FLAG_REGEN_DEFCONFIG=y;;
        -c|--clean|c|clean) FLAG_CLEAN_BUILD=y;;
        -h|--homedir|h|homedir) HOME_DIR="$2"; shift;;
        -t|--tcdir|t|tcdir) TC_DIR="$2"; shift;;
        -o|--outdir|o|outdir) OUT_DIR="$2"; shift;;
        --) shift; break;;
    esac
    shift
done

# Setup HOME dir
if [ $HOME_DIR ]; then
    HOME_DIR=$HOME_DIR
else
    HOME_DIR=$HOME
fi
echo -e "HOME directory is at $HOME_DIR/"

# Setup Toolchain dir
if [ $TC_DIR ]; then
    TC_DIR="$HOME_DIR/$TC_DIR"
else
    TC_DIR="$HOME_DIR/tc"
fi
echo -e "Toolchain directory is at $TC_DIR/"

# Setup OUT dir
if [ $OUT_DIR ]; then
    OUT_DIR=$OUT_DIR
else
    OUT_DIR=out
fi
echo -e "Out directory is at $OUT_DIR/\n"

SECONDS=0 # builtin bash timer
ZIPNAME="QuicksilveR-redwood-$(date '+%Y%m%d-%H%M').zip"
if test -z "$(git rev-parse --show-cdup 2>/dev/null)" &&
   head=$(git rev-parse --verify HEAD 2>/dev/null); then
        ZIPNAME="${ZIPNAME::-4}-$(echo $head | cut -c1-8).zip"
fi
CLANG_DIR="$TC_DIR/clang-r450784d"
AK3_DIR="$HOME_DIR/AnyKernel3"
DEFCONFIG="redwood_defconfig"

MAKE_PARAMS="O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 \
	CROSS_COMPILE=$TC_DIR/bin/llvm-"

export PATH="$CLANG_DIR/bin:$PATH"

# Regenerate defconfig, if requested so
if [ "$FLAG_REGEN_DEFCONFIG" = 'y' ]; then
	make $MAKE_PARAMS $DEFCONFIG savedefconfig
	cp $OUT_DIR/defconfig arch/arm64/configs/$DEFCONFIG
	echo -e "\nSuccessfully regenerated defconfig at $DEFCONFIG"
	exit
fi

# Prep for a clean build, if requested so
if [ "$FLAG_CLEAN_BUILD" = 'y' ]; then
	echo -e "\nCleaning output folder..."
	rm -rf $OUT_DIR
fi

mkdir -p $OUT_DIR
make $MAKE_PARAMS $DEFCONFIG

echo -e "\nStarting compilation...\n"
make -j$(nproc --all) $MAKE_PARAMS 2> >(tee error.log >&2) || exit $?
make -j$(nproc --all) $MAKE_PARAMS INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install

kernel="$OUT_DIR/arch/arm64/boot/Image"
dtb="$OUT_DIR/arch/arm64/boot/dts/vendor/qcom/yupik.dtb"
dtbo="$OUT_DIR/arch/arm64/boot/dts/vendor/qcom/redwood-sm7325-overlay.dtbo"

if [ -f "$kernel" ] && [ -f "$dtb" ] && [ -f "$dtbo" ]; then
	echo -e "\nKernel compiled succesfully! Zipping up...\n"
	if [ -d "$AK3_DIR" ]; then
		cp -r $AK3_DIR AnyKernel3
		git -C AnyKernel3 checkout redwood &> /dev/null
	elif ! git clone -q https://github.com/BladeRunner-A2C/AnyKernel3; then
		echo -e "\nAnyKernel3 repo not found locally and couldn't clone from GitHub! Aborting..."
		exit 1
	fi
	cp $kernel AnyKernel3
	cp $dtb AnyKernel3/dtb
	python2 scripts/dtc/libfdt/mkdtboimg.py create AnyKernel3/dtbo.img --page_size=4096 $dtbo
	cp $(find $OUT_DIR/modules/lib/modules/5.4* -name '*.ko') AnyKernel3/modules/vendor/lib/modules/
	cp $OUT_DIR/modules/lib/modules/5.4*/modules.{alias,dep,softdep} AnyKernel3/modules/vendor/lib/modules
	cp $OUT_DIR/modules/lib/modules/5.4*/modules.order AnyKernel3/modules/vendor/lib/modules/modules.load
	sed -i 's/\(kernel\/[^: ]*\/\)\([^: ]*\.ko\)/\/vendor\/lib\/modules\/\2/g' AnyKernel3/modules/vendor/lib/modules/modules.dep
	sed -i 's/.*\///g' AnyKernel3/modules/vendor/lib/modules/modules.load
	rm -rf $OUT_DIR/arch/arm64/boot $OUT_DIR/modules
	cd AnyKernel3
	zip -r9 "../$ZIPNAME" * -x .git README.md *placeholder
	cd ..
	rm -rf AnyKernel3
	echo -e "\nCompleted in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s) !"
	echo "Zip: $ZIPNAME"
	echo -e "\nUploading...\n"
	ID=$(curl --progress-bar -T "$ZIPNAME" https://pixeldrain.com/api/file/ | cat | grep -Po '(?<="id":")[^"]*')
	echo -e "Download URL: https://pixeldrain.com/api/file/$ID?download"
else
	echo -e "\nCompilation failed!"
	exit 1
fi
