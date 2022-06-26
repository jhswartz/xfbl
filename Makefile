SIZE=1440k
VMA=0x7c00

dist: clean-dist configure assemble link
	mkdir -p dist
	misc/pack-dist obj/boot-${SIZE} ext/cmdline ext/kernel ext/initramfs \
	               dist/${SIZE}.img ${SIZE}

clean-dist:
	rm -f dist/${SIZE}.img

clean: clean-obj clean-bin clean-dist clean-iso

iso: clean-iso dist
	mkdir -p iso
	genisoimage -o iso/${SIZE}.iso -b ${SIZE}.img dist

clean-iso:
	rm -f iso/${SIZE}.iso

iso-test:
	qemu-system-i386 -m 24 -cdrom iso/${SIZE}.iso

configure:
	misc/generate-config ext/kernel ext/initramfs src/config.s

assemble: clean-obj
	mkdir -p obj
	as -o obj/boot-${SIZE}.o src/config.s src/floppy/${SIZE}.s src/boot.s

clean-obj:
	rm -f obj/boot-${SIZE}.o

link: clean-bin
	ld -o obj/boot-${SIZE} -Ttext=${VMA} --oformat binary \
	   -e init obj/boot-${SIZE}.o

clean-bin:
	rm -f obj/boot-${SIZE}

disassemble:
	objdump -D -m i8086 -b binary --adjust-vma=${VMA} obj/boot-${SIZE}

test: test-${SIZE}

test-1440k:
	qemu-system-i386 -s -S -m 24 \
	                 -drive if=none,file=dist/${SIZE}.img \
	                 -device floppy,drive=none0,drive-type=144

test-2880k:
	qemu-system-i386 -s -S -m 24 \
	                 -drive if=none,file=dist/${SIZE}.img \
	                 -device floppy,drive=none0,drive-type=288

debug:
	gdb -q -ix misc/gdb/init \
	       -ex "target remote localhost:1234" \
	       -ex "b *${VMA}"
