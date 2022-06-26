.equ LBA_START,                 0x01
.equ RETRY_COUNT,               0x05

.equ I8042_OUTPUT_BUFFER,       0x60
.equ I8042_COMMAND_REGISTER,    0x64
.equ I8042_STATUS_REGISTER,     0x64
.equ I8042_OUTPUT_STATUS,       0x01
.equ I8042_WRITE_COMMAND,       0xd1
.equ I8042_NULL_COMMAND,        0xff
.equ I8042_ENABLE_A20,          0xdf

.equ SETUP_SEGMENT,             0x1000
.equ SETUP_ADDRESS,             (SETUP_SEGMENT << 4)
.equ STAGING_SEGMENT,           0x2000
.equ STAGING_ADDRESS,           (STAGING_SEGMENT << 4)
.equ STACK_OFFSET,              0x7c00
.equ CMDLINE_ADDRESS,           0x7e00
.equ KERNEL_ADDRESS,            0x00100000

.equ SETUP_SECTORS,             0x01f1
.equ SETUP_SECTORS_MIN,         0x04
.equ SYSTEM_SIZE,               0x01f4
.equ HEADER_MAGIC,              0x0202
.equ HEADER_MAGIC_VALUE,        0x53726448
.equ PROTOCOL_VERSION,          0x0206
.equ PROTOCOL_VERSION_MIN,      0x020a
.equ LOADER_TYPE,               0x0210
.equ LOADER_UNASSIGNED,         0xff
.equ LOAD_FLAGS,                0x0211
.equ CAN_USE_HEAP,              0x80
.equ LOADED_HIGH,               0x00
.equ RAMDISK_IMAGE,             0x0218
.equ RAMDISK_SIZE,              0x021c
.equ HEAP_END_POINTER,          0x0224
.equ CMDLINE_POINTER,           0x0228

.code16
.global init 

init:
        # Skip the following data, and ensure CS is 0.
        ljmp    $0x0000, $start

gdt:            .quad   0x0000000000000000
flat:           .byte   0xff, 0xff, 0x00, 0x00, 0x00, 0x92, 0xcf, 0x00
gdt_info:       .word   (. - gdt) - 1
                .long   gdt
error:          .byte   0x30
drive:          .byte   0x00
retries:        .byte   RETRY_COUNT
lba:            .long   LBA_START
offset:         .long   0x00007e00

start:
        # Disable interrupts.
        cli

        # Configure a few segment registers and the stack.
        xorw    %ax, %ax
        movw    %ax, %ds
        movw    %ax, %es
        movw    %ax, %ss
        movw    $STACK_OFFSET, %sp

        # Store the boot drive.
        movb    %dl, drive

        # Preserve DS and ES.
        push    %ds
        push    %es

        # Attempt to enable A20 via BIOS.
        movw    $0x2401, %ax
        int     $0x15
        jnc     a20_enabled 

        # If that didn't work, naively assume A20 will be enabled via i8042.
        mov     $I8042_WRITE_COMMAND, %al
        out     %al, $I8042_COMMAND_REGISTER
        call    wait_for_i8042
        mov     $I8042_ENABLE_A20, %al
        out     %al, $I8042_OUTPUT_BUFFER
        call    wait_for_i8042
        mov     $I8042_NULL_COMMAND, %al
        out     %al, $I8042_COMMAND_REGISTER
        call    wait_for_i8042

a20_enabled:
        # Switch to protected mode.
        lgdt    (gdt_info)
        movl    %cr0, %eax
        orb     $0x01, %al
        movl    %eax, %cr0

        # Switch to unreal mode.
        movw    $0x08, %bx
        movw    %bx, %ds
        movw    %bx, %es
        movw    %bx, %fs
        movw    %bx, %gs

        andb    $0xfe, %al
        movl    %eax, %cr0

        # Restore ES and DS.
        pop     %es
        pop     %ds

        # Enable interrupts.
        sti

load:
        # Read the kernel command line from the next sector on disk.
        call    read_sector

        # Setup ES for setup code access.
        push    $SETUP_SEGMENT
        pop     %es

        # Read the first sector of the setup header.
        xorl    %ecx, %ecx
        movl    %ecx, offset
        incb    %cl
        call    read_sectors

        # Fetch the rest of the setup code.
        movb    %es:(SETUP_SECTORS), %cl
        testb   %cl, %cl
        jnz     1f
        movb    $SETUP_SECTORS_MIN, %cl
1:      call    read_sectors

        # Does the header seem reasonable?
        cmpl    $HEADER_MAGIC_VALUE, %es:(HEADER_MAGIC)
        jne     bad_kernel_magic
        cmpl    $PROTOCOL_VERSION_MIN, %es:(PROTOCOL_VERSION)
        jl      old_protocol

        # Tell the kernel about the heap, loader, and command line.
        andb    $(CAN_USE_HEAP|LOADED_HIGH), %es:(LOAD_FLAGS)
        movw    $(SETUP_ADDRESS - 0x200), %es:(HEAP_END_POINTER)
        movb    $LOADER_UNASSIGNED, %es:(LOADER_TYPE)
        movl    $CMDLINE_ADDRESS, %es:(CMDLINE_POINTER)

        # Store the rest of the kernel.
        movl    %es:(SYSTEM_SIZE), %ecx
        shrl    $0x05, %ecx
        incl    %ecx
        movl    $KERNEL_ADDRESS, %edi
        call    load_sectors

        # Store initramfs.
        movl    $INITRAMFS_SIZE, %ecx
        movl    %ecx, %es:(RAMDISK_SIZE)
        shrl    $0x09, %ecx
        incl    %ecx
        movl    $INITRAMFS_ADDRESS, %edi
        movl    %edi, %es:(RAMDISK_IMAGE)
        call    load_sectors

start_linux:
        # Clear interrupts.
        cli

        # Initialise segment registers.
        movw    $SETUP_SEGMENT, %ax
        movw    %ax, %ds
        movw    %ax, %es
        movw    %ax, %fs
        movw    %ax, %gs

        # Initialise the stack.
        movw    %ax, %ss
        movw    $(SETUP_ADDRESS - 0x200), %sp
        
        # Take gold in the long jump final?
        ljmp    $0x1020,$0x0000
        
wait_for_i8042:
        in      $I8042_STATUS_REGISTER, %al
        test    $I8042_OUTPUT_STATUS, %al
        jnz     wait_for_i8042
        ret

load_sectors:
        # Preserve ES.
        push    %es

        # Read sectors into the staging segment.
        push    $STAGING_SEGMENT
        pop     %es

        # Reset staging offset.
        xorl    %eax, %eax
        movl    %eax, offset

        # Preserve the sector count.
1:      push    %ecx

        # Read a sector into the staging segment.
        call    read_sector

        # Move the sector into high memory.
        movl    $STAGING_ADDRESS, %esi
        call    move_sector

        # Repeat until all sectors have been loaded.
        pop     %ecx
        loop    1b

        # Restore ES.
        pop     %es     
        ret

read_sectors:
        # Preserve the remaining sector count.
1:      push    %ecx

        # Read sector from source to destination
        call    read_sector
        addw    $SECTOR_SIZE, offset

        # Repeat until remaining count is zero.
        pop     %ecx
        loop    1b 
        ret

retry_read_sector:
        # Emit '?' to indicate a failed read.
        movb    $'?', %al
        call    emit

        # Reset drive.
        xorw    %ax, %ax 
        movb    drive, %dl
        int     $0x13

        # Decrement retry counter, and abort if zero.
        decb    retries
        jz      read_failed 

read_sector:
        # Divide LBA by Sectors per Cylinder.
        movw    lba, %ax
        xorw    %dx, %dx
        movw    $SECTORS_PER_CYLINDER, %bx
        divw    %bx

        # Now...
        #   AX = Temp         = LBA / Sectors per Cylinder
        #   DX = (Sector - 1) = LBA % Sectors per Cylinder

        # Prepare Sector Number.
        incw    %dx
        movb    %dl, %cl

        # Divide Temp by Heads.
        xorw    %dx, %dx
        movw    $HEADS, %bx
        divw    %bx

        # Now...
        #   AX = Cylinder = Temp / Heads
        #   DX = Head     = Temp % Heads

        # Prepare Cylinder and Head Numbers.
        movb    %al, %ch
        movb    %dl, %dh

        # INT 0x13 AH 0x02 expects:
        #   AL    = Sector Count
        #   CH    = Cylinder Number[7:0]
        #   CL    = Cylinder Number[9:8] | Sector Number[5:0]
        #   DH    = Head Number
        #   DL    = Drive Number
        #   ES:BX = Buffer

        movb    drive, %dl
        movw    offset, %bx
        movw    $0x0201, %ax
        int     $0x13

        # Did it fail?
        jc      retry_read_sector 

        # Emit '.' to indicate success.
        movb    $'.', %al
        call    emit

        # Restore the retry count, and increment LBA.
        movb    $RETRY_COUNT, retries
        incl    lba
        ret

move_sector:
        # Set the number of 4-byte chunks to copy.
        movl    $(SECTOR_SIZE / 4), %ecx

        # Copy data from source to destination.
1:      movl    (%esi), %eax
        movl    %eax, (%edi)
        addl    $0x04, %esi
        addl    $0x04, %edi
        loop    1b
        ret

read_failed:
        incb    error

old_protocol:
        incb    error

bad_kernel_magic:
        incb    error

emit_error:
        movb    error, %al
        call    emit
        jmp     .

emit:
        movb    $0x0e, %ah
        movw    $0x07, %bx
        int     $0x10
        ret

padding:        .fill   510 - (. - init), 1, 0
magic:          .word   0xaa55
