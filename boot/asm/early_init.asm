; frOSt Early Init Stub - x86-64 Assembly
; Optimized early boot routines called from initramfs before Python init
; Performs hardware detection, memory mapping, and fast filesystem setup
;
; This runs as an ELF64 executable called by the initramfs /init script
; before handing off to the Python-based frost-init system.

BITS 64

; ============================================================
; ELF64 Header (minimal, statically linked, no libc)
; ============================================================
section .text
global _start

; Syscall numbers (x86-64 Linux)
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_stat        4
%define SYS_mmap        9
%define SYS_mount       165
%define SYS_mkdir       83
%define SYS_getdents64  217
%define SYS_reboot      169
%define SYS_sysinfo     99
%define SYS_exit        60
%define SYS_read        0
%define SYS_ioctl       16
%define SYS_pivot_root  155
%define SYS_chdir       80
%define SYS_umount2     166
%define SYS_symlink     88
%define SYS_chroot      161
%define SYS_execve      59

; Mount flags
%define MS_RDONLY       1
%define MS_NOSUID       2
%define MS_NODEV        4
%define MS_NOEXEC       8
%define MS_REMOUNT      32

; Open flags
%define O_RDONLY        0
%define O_WRONLY        1
%define O_RDWR          2
%define O_CREAT         0x40
%define O_TRUNC         0x200

; stdout/stderr
%define STDOUT          1
%define STDERR          2

; ============================================================
; Entry Point
; ============================================================
_start:
    ; Align stack to 16 bytes (ABI requirement)
    and     rsp, -16

    ; Print boot banner
    mov     rdi, STDOUT
    lea     rsi, [rel msg_banner]
    mov     rdx, msg_banner_len
    call    sys_write

    ; Step 1: Mount essential virtual filesystems
    call    mount_proc
    test    eax, eax
    jnz     .proc_fail
    call    mount_sysfs
    test    eax, eax
    jnz     .sysfs_fail
    call    mount_devtmpfs
    test    eax, eax
    jnz     .devtmpfs_fail

    ; Step 2: Detect available RAM
    call    detect_memory
    ; rax = total RAM in bytes

    ; Step 3: Create essential directories for overlay
    call    create_overlay_dirs

    ; Step 4: Mount tmpfs for transient layer (sized to 50% of RAM)
    call    mount_tmpfs_overlay

    ; Step 5: Detect and catalog block devices
    call    detect_block_devices

    ; Print success
    mov     rdi, STDOUT
    lea     rsi, [rel msg_done]
    mov     rdx, msg_done_len
    call    sys_write

    ; Exit with 0 = success, Python init will take over
    xor     edi, edi
    mov     eax, SYS_exit
    syscall

.proc_fail:
    lea     rsi, [rel msg_proc_fail]
    mov     rdx, msg_proc_fail_len
    jmp     .error_exit

.sysfs_fail:
    lea     rsi, [rel msg_sysfs_fail]
    mov     rdx, msg_sysfs_fail_len
    jmp     .error_exit

.devtmpfs_fail:
    lea     rsi, [rel msg_devtmpfs_fail]
    mov     rdx, msg_devtmpfs_fail_len
    jmp     .error_exit

.error_exit:
    mov     rdi, STDERR
    call    sys_write
    mov     edi, 1
    mov     eax, SYS_exit
    syscall


; ============================================================
; Mount /proc
; ============================================================
mount_proc:
    push    rbx

    ; mkdir /proc
    lea     rdi, [rel path_proc]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall
    ; ignore error (may already exist)

    ; mount -t proc proc /proc
    lea     rdi, [rel fs_proc]       ; source
    lea     rsi, [rel path_proc]     ; target
    lea     rdx, [rel fs_proc]       ; fstype
    xor     r10d, r10d               ; flags = 0
    xor     r8d, r8d                 ; data = NULL
    mov     eax, SYS_mount
    syscall

    pop     rbx
    ret

; ============================================================
; Mount /sys
; ============================================================
mount_sysfs:
    push    rbx

    lea     rdi, [rel path_sys]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    lea     rdi, [rel fs_sysfs]
    lea     rsi, [rel path_sys]
    lea     rdx, [rel fs_sysfs]
    xor     r10d, r10d
    xor     r8d, r8d
    mov     eax, SYS_mount
    syscall

    pop     rbx
    ret

; ============================================================
; Mount /dev (devtmpfs)
; ============================================================
mount_devtmpfs:
    push    rbx

    lea     rdi, [rel path_dev]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    lea     rdi, [rel fs_devtmpfs]
    lea     rsi, [rel path_dev]
    lea     rdx, [rel fs_devtmpfs]
    mov     r10d, MS_NOSUID | MS_NOEXEC
    xor     r8d, r8d
    mov     eax, SYS_mount
    syscall

    pop     rbx
    ret

; ============================================================
; Detect total system memory via sysinfo
; Returns total RAM in rax
; ============================================================
detect_memory:
    push    rbx
    sub     rsp, 128            ; struct sysinfo buffer

    mov     rdi, rsp
    mov     eax, SYS_sysinfo
    syscall
    test    eax, eax
    jnz     .mem_fail

    ; sysinfo.totalram is at offset 32 (8 bytes)
    mov     rax, [rsp + 32]
    ; sysinfo.mem_unit is at offset 104 (4 bytes)
    mov     ecx, [rsp + 104]
    ; total = totalram * mem_unit
    imul    rax, rcx

    ; Store for later use
    mov     [rel total_ram], rax

    ; Print memory info
    push    rax
    mov     rdi, STDOUT
    lea     rsi, [rel msg_ram_prefix]
    mov     rdx, msg_ram_prefix_len
    call    sys_write
    pop     rax

    ; Convert to MB for display
    shr     rax, 20
    call    print_decimal

    mov     rdi, STDOUT
    lea     rsi, [rel msg_mb_suffix]
    mov     rdx, msg_mb_suffix_len
    call    sys_write

    mov     rax, [rel total_ram]
    add     rsp, 128
    pop     rbx
    ret

.mem_fail:
    ; Default to 512MB if sysinfo fails
    mov     rax, 512 * 1024 * 1024
    mov     [rel total_ram], rax
    add     rsp, 128
    pop     rbx
    ret

; ============================================================
; Create overlay directories
; ============================================================
create_overlay_dirs:
    push    rbx

    ; /frost - main mount point
    lea     rdi, [rel path_frost]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    ; /frost/lower - squashfs mount (read-only root)
    lea     rdi, [rel path_lower]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    ; /frost/upper - tmpfs transient layer
    lea     rdi, [rel path_upper]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    ; /frost/work - overlayfs workdir
    lea     rdi, [rel path_work]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    ; /frost/merged - final merged root
    lea     rdi, [rel path_merged]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    ; /frost/persist - persistence partition mount
    lea     rdi, [rel path_persist]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall

    pop     rbx
    ret

; ============================================================
; Mount tmpfs for transient overlay (50% of RAM)
; ============================================================
mount_tmpfs_overlay:
    push    rbx
    sub     rsp, 64

    ; Calculate 50% of RAM for tmpfs size
    mov     rax, [rel total_ram]
    shr     rax, 1              ; /2

    ; Build size= option string: "size=XXXM"
    shr     rax, 20             ; convert to MB
    lea     rdi, [rsp]
    lea     rsi, [rel tmpfs_size_prefix]
    ; Copy "size=" prefix
    mov     ecx, 5
.copy_prefix:
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     .copy_prefix

    ; Convert MB number to ASCII
    mov     rax, [rel total_ram]
    shr     rax, 21             ; /2 then /1048576 = RAM/2 in MB
    call    uint_to_ascii       ; rdi points past last digit
    mov     byte [rdi], 'M'
    mov     byte [rdi+1], 0

    ; mount -t tmpfs -o size=XXXM tmpfs /frost/upper
    lea     rdi, [rel fs_tmpfs]
    lea     rsi, [rel path_upper]
    lea     rdx, [rel fs_tmpfs]
    xor     r10d, r10d
    lea     r8, [rsp]           ; options: "size=XXXM"
    mov     eax, SYS_mount
    syscall

    mov     rdi, STDOUT
    lea     rsi, [rel msg_tmpfs_ok]
    mov     rdx, msg_tmpfs_ok_len
    call    sys_write

    add     rsp, 64
    pop     rbx
    ret

; ============================================================
; Detect block devices by reading /sys/block
; ============================================================
detect_block_devices:
    push    rbx
    push    r12
    sub     rsp, 1088           ; buffer for getdents64

    mov     rdi, STDOUT
    lea     rsi, [rel msg_scanning]
    mov     rdx, msg_scanning_len
    call    sys_write

    ; Open /sys/block
    lea     rdi, [rel path_sys_block]
    xor     esi, esi            ; O_RDONLY
    mov     eax, SYS_open
    syscall
    test    eax, eax
    js      .scan_done
    mov     r12d, eax           ; save fd

.read_entries:
    mov     edi, r12d
    lea     rsi, [rsp]
    mov     edx, 1088
    mov     eax, SYS_getdents64
    syscall
    test    eax, eax
    jle     .close_dir

    ; Walk directory entries
    xor     ebx, ebx
.next_entry:
    cmp     ebx, eax
    jge     .read_entries

    ; struct linux_dirent64: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name(...)
    movzx   ecx, word [rsp + rbx + 16]  ; d_reclen
    lea     rdi, [rsp + rbx + 19]        ; d_name

    ; Skip . and ..
    cmp     byte [rdi], '.'
    je      .skip_entry

    ; Print device name
    push    rax
    push    rcx
    push    rbx
    mov     rdi, STDOUT
    lea     rsi, [rel msg_dev_prefix]
    mov     rdx, msg_dev_prefix_len
    call    sys_write

    ; Print the device name
    lea     rsi, [rsp]              ; need to recalculate
    pop     rbx
    push    rbx
    lea     rsi, [rsp + 24 + rbx + 19]  ; account for pushed regs (3*8=24)
    ; Find string length
    xor     edx, edx
.strlen:
    cmp     byte [rsi + rdx], 0
    je      .print_name
    inc     edx
    jmp     .strlen
.print_name:
    mov     rdi, STDOUT
    call    sys_write

    mov     rdi, STDOUT
    lea     rsi, [rel msg_newline]
    mov     rdx, 1
    call    sys_write

    pop     rbx
    pop     rcx
    pop     rax

.skip_entry:
    add     ebx, ecx
    jmp     .next_entry

.close_dir:
    mov     edi, r12d
    mov     eax, SYS_close
    syscall

.scan_done:
    add     rsp, 1088
    pop     r12
    pop     rbx
    ret

; ============================================================
; Utility: sys_write wrapper
; rdi = fd, rsi = buf, rdx = len
; ============================================================
sys_write:
    mov     eax, SYS_write
    syscall
    ret

; ============================================================
; Utility: print unsigned decimal number in rax
; ============================================================
print_decimal:
    push    rbx
    push    rcx
    sub     rsp, 24
    lea     rdi, [rsp + 23]
    mov     byte [rdi], 0
    dec     rdi
    mov     rcx, 10
    test    rax, rax
    jnz     .convert
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .print_it
.convert:
    test    rax, rax
    jz      .print_it
    xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    jmp     .convert
.print_it:
    inc     rdi
    lea     rsi, [rdi]
    lea     rcx, [rsp + 23]
    sub     rcx, rdi
    mov     rdx, rcx
    mov     rdi, STDOUT
    call    sys_write
    add     rsp, 24
    pop     rcx
    pop     rbx
    ret

; ============================================================
; Utility: Convert uint in rax to ASCII at [rdi]
; Returns rdi pointing past last digit
; ============================================================
uint_to_ascii:
    push    rbx
    push    rcx
    push    rdx
    mov     rcx, 10
    mov     rbx, rdi            ; save start
    ; First, handle 0
    test    rax, rax
    jnz     .ua_convert
    mov     byte [rdi], '0'
    inc     rdi
    jmp     .ua_done
.ua_convert:
    ; Push digits in reverse
    xor     r8d, r8d            ; digit count
.ua_push:
    test    rax, rax
    jz      .ua_reverse
    xor     edx, edx
    div     rcx
    add     dl, '0'
    push    rdx
    inc     r8d
    jmp     .ua_push
.ua_reverse:
    test    r8d, r8d
    jz      .ua_done
    pop     rdx
    mov     [rdi], dl
    inc     rdi
    dec     r8d
    jmp     .ua_reverse
.ua_done:
    pop     rdx
    pop     rcx
    pop     rbx
    ret


; ============================================================
; Data Section
; ============================================================
section .data

; Boot messages
msg_banner:     db 0x1B, '[1;36m'
                db '  __       ___  ____  _   ', 10
                db ' / _|_ __ / _ \/ ___|| |_ ', 10
                db '| |_| |__| | | \___ \| __|', 10
                db '|  _| |  | |_| |___) | |_ ', 10
                db '|_| |_|   \___/|____/ \__|', 10
                db 0x1B, '[0m', 10
                db 0x1B, '[1;37m', 'frOSt Early Init v1.0 (x86-64 asm)', 0x1B, '[0m', 10
                db '-----------------------------------', 10, 0
msg_banner_len  equ $ - msg_banner

msg_done:       db 0x1B, '[1;32m', '[OK] Early init complete, handing off to frost-init', 0x1B, '[0m', 10, 0
msg_done_len    equ $ - msg_done

msg_proc_fail:      db 0x1B, '[1;31m', '[FAIL] Cannot mount /proc', 0x1B, '[0m', 10, 0
msg_proc_fail_len   equ $ - msg_proc_fail

msg_sysfs_fail:     db 0x1B, '[1;31m', '[FAIL] Cannot mount /sys', 0x1B, '[0m', 10, 0
msg_sysfs_fail_len  equ $ - msg_sysfs_fail

msg_devtmpfs_fail:  db 0x1B, '[1;31m', '[FAIL] Cannot mount /dev', 0x1B, '[0m', 10, 0
msg_devtmpfs_fail_len equ $ - msg_devtmpfs_fail

msg_ram_prefix:     db '[INFO] Detected RAM: ', 0
msg_ram_prefix_len  equ $ - msg_ram_prefix

msg_mb_suffix:      db ' MB', 10, 0
msg_mb_suffix_len   equ $ - msg_mb_suffix

msg_tmpfs_ok:       db '[OK] Transient tmpfs overlay mounted', 10, 0
msg_tmpfs_ok_len    equ $ - msg_tmpfs_ok

msg_scanning:       db '[INFO] Scanning block devices...', 10, 0
msg_scanning_len    equ $ - msg_scanning

msg_dev_prefix:     db '  -> /dev/', 0
msg_dev_prefix_len  equ $ - msg_dev_prefix

msg_newline:        db 10

; Filesystem type strings
fs_proc:        db 'proc', 0
fs_sysfs:       db 'sysfs', 0
fs_devtmpfs:    db 'devtmpfs', 0
fs_tmpfs:       db 'tmpfs', 0

; Path strings
path_proc:      db '/proc', 0
path_sys:       db '/sys', 0
path_dev:       db '/dev', 0
path_frost:     db '/frost', 0
path_lower:     db '/frost/lower', 0
path_upper:     db '/frost/upper', 0
path_work:      db '/frost/work', 0
path_merged:    db '/frost/merged', 0
path_persist:   db '/frost/persist', 0
path_sys_block: db '/sys/block', 0

; tmpfs mount option prefix
tmpfs_size_prefix: db 'size=', 0

section .bss
total_ram:      resq 1
