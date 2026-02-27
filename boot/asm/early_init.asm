; =============================================================================
; frOSt Early Init - x86-64 Assembly
; =============================================================================
; Bare-metal early boot stub, runs before shell bootstrap + Python init.
; No libc, pure Linux syscalls.
;
; Responsibilities:
;   1. Mount /proc, /sys, /dev (devtmpfs)
;   2. Detect RAM, calculate tmpfs size
;   3. Create overlay directory structure
;   4. Mount tmpfs for transient overlay layer
;   5. Set up /dev/console, /dev/null, /dev/zero
;   6. Configure kernel hotplug for mdev
;   7. Scan /sys/block and report block devices
;   8. Exit 0 -> hand off to shell bootstrap -> Python frost_init
; =============================================================================

BITS 64

section .text
global _start

; ── Syscall numbers (x86-64 Linux) ──
%define SYS_read        0
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_stat        4
%define SYS_mmap        9
%define SYS_ioctl       16
%define SYS_mount       165
%define SYS_mkdir       83
%define SYS_mknod       133
%define SYS_getdents64  217
%define SYS_reboot      169
%define SYS_sysinfo     99
%define SYS_exit        60
%define SYS_execve      59
%define SYS_chdir       80
%define SYS_symlink     88

; ── Mount flags ──
%define MS_NOSUID       2
%define MS_NODEV        4
%define MS_NOEXEC       8

; ── Open flags ──
%define O_RDONLY        0
%define O_WRONLY        1
%define O_RDWR          2
%define O_CREAT         0x40
%define O_TRUNC         0x200

; ── mknod modes ──
%define S_IFCHR         0o020000

; ── File descriptors ──
%define STDOUT          1
%define STDERR          2

; =============================================================================
; Entry Point
; =============================================================================
_start:
    and     rsp, -16                    ; ABI stack alignment

    ; ── Print boot banner ──
    mov     rdi, STDOUT
    lea     rsi, [rel msg_banner]
    mov     rdx, msg_banner_len
    call    sys_write

    ; ── Step 1: Mount virtual filesystems ──
    call    mount_proc
    test    eax, eax
    jnz     .fail_proc

    call    mount_sysfs
    test    eax, eax
    jnz     .fail_sysfs

    call    mount_devtmpfs
    test    eax, eax
    jnz     .fail_devtmpfs

    ; ── Step 2: Detect RAM ──
    call    detect_memory

    ; ── Step 3: Create overlay directories ──
    call    create_overlay_dirs

    ; ── Step 4: Mount tmpfs overlay ──
    call    mount_tmpfs_overlay

    ; ── Step 5: Create essential device nodes ──
    call    create_dev_nodes

    ; ── Step 6: Configure mdev hotplug ──
    call    setup_mdev

    ; ── Step 7: Scan block devices ──
    call    detect_block_devices

    ; ── Done ──
    mov     rdi, STDOUT
    lea     rsi, [rel msg_done]
    mov     rdx, msg_done_len
    call    sys_write

    xor     edi, edi
    mov     eax, SYS_exit
    syscall

.fail_proc:
    lea     rsi, [rel msg_proc_fail]
    mov     rdx, msg_proc_fail_len
    jmp     .error_exit
.fail_sysfs:
    lea     rsi, [rel msg_sysfs_fail]
    mov     rdx, msg_sysfs_fail_len
    jmp     .error_exit
.fail_devtmpfs:
    lea     rsi, [rel msg_devtmpfs_fail]
    mov     rdx, msg_devtmpfs_fail_len
    jmp     .error_exit
.error_exit:
    mov     rdi, STDERR
    call    sys_write
    mov     edi, 1
    mov     eax, SYS_exit
    syscall


; =============================================================================
; Mount /proc
; =============================================================================
mount_proc:
    push    rbx
    lea     rdi, [rel path_proc]
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall
    lea     rdi, [rel fs_proc]
    lea     rsi, [rel path_proc]
    lea     rdx, [rel fs_proc]
    xor     r10d, r10d
    xor     r8d, r8d
    mov     eax, SYS_mount
    syscall
    pop     rbx
    ret

; =============================================================================
; Mount /sys
; =============================================================================
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

; =============================================================================
; Mount /dev (devtmpfs)
; =============================================================================
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

; =============================================================================
; Detect total system memory via sysinfo
; =============================================================================
detect_memory:
    push    rbx
    sub     rsp, 128

    mov     rdi, rsp
    mov     eax, SYS_sysinfo
    syscall
    test    eax, eax
    jnz     .mem_fail

    mov     rax, [rsp + 32]             ; sysinfo.totalram
    mov     ecx, [rsp + 104]            ; sysinfo.mem_unit
    imul    rax, rcx
    mov     [rel total_ram], rax

    push    rax
    mov     rdi, STDOUT
    lea     rsi, [rel msg_ram_prefix]
    mov     rdx, msg_ram_prefix_len
    call    sys_write
    pop     rax

    shr     rax, 20                     ; bytes -> MB
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
    mov     rax, 512 * 1024 * 1024
    mov     [rel total_ram], rax
    add     rsp, 128
    pop     rbx
    ret

; =============================================================================
; Create overlay directory tree
; =============================================================================
create_overlay_dirs:
    push    rbx

    ; Create all directories: /frost, /frost/lower, /frost/upper,
    ; /frost/work, /frost/merged, /frost/persist, /frost/probe
    %macro mkdir_path 1
        lea     rdi, [rel %1]
        mov     esi, 0o755
        mov     eax, SYS_mkdir
        syscall
    %endmacro

    mkdir_path path_frost
    mkdir_path path_lower
    mkdir_path path_upper
    mkdir_path path_work
    mkdir_path path_merged
    mkdir_path path_persist
    mkdir_path path_probe

    pop     rbx
    ret

; =============================================================================
; Mount tmpfs for transient overlay layer (50% of RAM, min 512M)
; =============================================================================
mount_tmpfs_overlay:
    push    rbx
    sub     rsp, 64

    ; Calculate 50% of RAM in MB
    mov     rax, [rel total_ram]
    shr     rax, 21                     ; bytes / 2 / 1048576 = MB

    ; Enforce minimum 512MB
    cmp     rax, 512
    jge     .tmpfs_size_ok
    mov     rax, 512
.tmpfs_size_ok:

    ; Build option string "size=XXXM" on stack
    lea     rdi, [rsp]
    lea     rsi, [rel tmpfs_size_prefix]
    mov     ecx, 5
.cp:
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     .cp

    ; Recalculate size for conversion
    mov     rax, [rel total_ram]
    shr     rax, 21
    cmp     rax, 512
    jge     .conv_ok
    mov     rax, 512
.conv_ok:
    call    uint_to_ascii
    mov     byte [rdi], 'M'
    mov     byte [rdi+1], 0

    ; mount -t tmpfs -o size=XXXM tmpfs /frost/upper
    lea     rdi, [rel fs_tmpfs]
    lea     rsi, [rel path_upper]
    lea     rdx, [rel fs_tmpfs]
    xor     r10d, r10d
    lea     r8, [rsp]
    mov     eax, SYS_mount
    syscall

    mov     rdi, STDOUT
    lea     rsi, [rel msg_tmpfs_ok]
    mov     rdx, msg_tmpfs_ok_len
    call    sys_write

    add     rsp, 64
    pop     rbx
    ret

; =============================================================================
; Create essential device nodes: /dev/console, /dev/null, /dev/zero, /dev/tty
; =============================================================================
create_dev_nodes:
    push    rbx

    ; /dev/console  c 5 1  mode 0622
    lea     rdi, [rel dev_console]
    mov     esi, S_IFCHR | 0o622
    mov     edx, (5 << 8) | 1           ; makedev(5, 1)
    mov     eax, SYS_mknod
    syscall

    ; /dev/null     c 1 3  mode 0666
    lea     rdi, [rel dev_null]
    mov     esi, S_IFCHR | 0o666
    mov     edx, (1 << 8) | 3
    mov     eax, SYS_mknod
    syscall

    ; /dev/zero     c 1 5  mode 0666
    lea     rdi, [rel dev_zero]
    mov     esi, S_IFCHR | 0o666
    mov     edx, (1 << 8) | 5
    mov     eax, SYS_mknod
    syscall

    ; /dev/tty      c 5 0  mode 0666
    lea     rdi, [rel dev_tty]
    mov     esi, S_IFCHR | 0o666
    mov     edx, (5 << 8) | 0
    mov     eax, SYS_mknod
    syscall

    pop     rbx
    ret

; =============================================================================
; Set up mdev as hotplug handler and run initial device scan
; =============================================================================
setup_mdev:
    push    rbx

    ; Write "/bin/mdev" to /proc/sys/kernel/hotplug
    lea     rdi, [rel path_hotplug]
    mov     esi, O_WRONLY
    mov     eax, SYS_open
    syscall
    test    eax, eax
    js      .mdev_skip_hotplug
    mov     ebx, eax                    ; save fd

    lea     rsi, [rel mdev_path]
    mov     edx, mdev_path_len
    mov     edi, ebx
    mov     eax, SYS_write
    syscall

    mov     edi, ebx
    mov     eax, SYS_close
    syscall
.mdev_skip_hotplug:

    ; Print status
    mov     rdi, STDOUT
    lea     rsi, [rel msg_mdev]
    mov     rdx, msg_mdev_len
    call    sys_write

    pop     rbx
    ret

; =============================================================================
; Detect block devices by reading /sys/block directory entries
; =============================================================================
detect_block_devices:
    push    rbx
    push    r12
    sub     rsp, 1088

    mov     rdi, STDOUT
    lea     rsi, [rel msg_scanning]
    mov     rdx, msg_scanning_len
    call    sys_write

    lea     rdi, [rel path_sys_block]
    xor     esi, esi
    mov     eax, SYS_open
    syscall
    test    eax, eax
    js      .scan_done
    mov     r12d, eax

.read_loop:
    mov     edi, r12d
    lea     rsi, [rsp]
    mov     edx, 1088
    mov     eax, SYS_getdents64
    syscall
    test    eax, eax
    jle     .close_dir

    xor     ebx, ebx
.next_ent:
    cmp     ebx, eax
    jge     .read_loop

    movzx   ecx, word [rsp + rbx + 16]
    lea     rdi, [rsp + rbx + 19]

    ; Skip . and .. and loop/ram devices
    cmp     byte [rdi], '.'
    je      .skip_ent
    cmp     byte [rdi], 'l'             ; skip loop*
    jne     .not_loop
    cmp     byte [rdi+1], 'o'
    je      .skip_ent
.not_loop:
    cmp     byte [rdi], 'r'             ; skip ram*
    jne     .not_ram
    cmp     byte [rdi+1], 'a'
    je      .skip_ent
.not_ram:

    ; Print "  -> /dev/<name>\n"
    push    rax
    push    rcx
    push    rbx
    mov     rdi, STDOUT
    lea     rsi, [rel msg_dev_prefix]
    mov     rdx, msg_dev_prefix_len
    call    sys_write

    pop     rbx
    push    rbx
    lea     rsi, [rsp + 24 + rbx + 19]
    xor     edx, edx
.slen:
    cmp     byte [rsi + rdx], 0
    je      .pname
    inc     edx
    jmp     .slen
.pname:
    mov     rdi, STDOUT
    call    sys_write
    mov     rdi, STDOUT
    lea     rsi, [rel msg_newline]
    mov     rdx, 1
    call    sys_write
    pop     rbx
    pop     rcx
    pop     rax

.skip_ent:
    add     ebx, ecx
    jmp     .next_ent

.close_dir:
    mov     edi, r12d
    mov     eax, SYS_close
    syscall
.scan_done:
    add     rsp, 1088
    pop     r12
    pop     rbx
    ret

; =============================================================================
; Utility: sys_write wrapper
; =============================================================================
sys_write:
    mov     eax, SYS_write
    syscall
    ret

; =============================================================================
; Utility: print unsigned decimal number (rax) to stdout
; =============================================================================
print_decimal:
    push    rbx
    push    rcx
    sub     rsp, 24
    lea     rdi, [rsp + 23]
    mov     byte [rdi], 0
    dec     rdi
    mov     rcx, 10
    test    rax, rax
    jnz     .pd_conv
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .pd_print
.pd_conv:
    test    rax, rax
    jz      .pd_print
    xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    jmp     .pd_conv
.pd_print:
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

; =============================================================================
; Utility: convert uint in rax to ASCII at [rdi], advance rdi
; =============================================================================
uint_to_ascii:
    push    rbx
    push    rcx
    push    rdx
    mov     rcx, 10
    test    rax, rax
    jnz     .ua_convert
    mov     byte [rdi], '0'
    inc     rdi
    jmp     .ua_done
.ua_convert:
    xor     r8d, r8d
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


; =============================================================================
; Data Section
; =============================================================================
section .data

; ── Boot banner (cyan frOSt ASCII art with snowflake accents) ──
msg_banner:
    db 10
    db 0x1B, '[1;34m'
    db '   ┌──────────────────────────────────────────────┐', 10
    db '   │', 0x1B, '[1;36m'
    db '  ❄  frOSt Kernel Bootstrap  ❄                ', 0x1B, '[1;34m', '│', 10
    db '   └──────────────────────────────────────────────┘', 10
    db 0x1B, '[0m', 10
    db 0x1B, '[1;36m'
    db '   :::::::::: :::::::::   ::::::::   ::::::::  ::::::::::', 10
    db '   :+:        :+:    :+: :+:    :+: :+:    :+:    :+:    ', 10
    db '   +:+        +:+    +:+ +:+    +:+ +:+           +:+    ', 10
    db '   :#::+::#   +#++:++#:  +#+    +:+ +#++:++#++    +#+    ', 10
    db '   +#+        +#+    +#+ +#+    +#+        +#+    +#+     ', 10
    db '   #+#        #+#    #+# #+#    #+# #+#    #+#    #+#     ', 10
    db '   ###        ###    ###  ########   ########     ###     ', 10
    db 0x1B, '[0m', 10
    db 0x1B, '[1;37m', '  Frozen Operating System v3.0', 0x1B, '[0m', 10
    db 0x1B, '[0;36m', '  x86-64 Assembly + Python Init', 0x1B, '[0m', 10
    db '  ──────────────────────────────────────────', 10, 0
msg_banner_len equ $ - msg_banner

msg_done:
    db 0x1B, '[1;32m', '[frOSt] Assembly init complete -> shell bootstrap', 0x1B, '[0m', 10, 0
msg_done_len equ $ - msg_done

msg_proc_fail:
    db 0x1B, '[1;31m', '[frOSt] FATAL: Cannot mount /proc', 0x1B, '[0m', 10, 0
msg_proc_fail_len equ $ - msg_proc_fail

msg_sysfs_fail:
    db 0x1B, '[1;31m', '[frOSt] FATAL: Cannot mount /sys', 0x1B, '[0m', 10, 0
msg_sysfs_fail_len equ $ - msg_sysfs_fail

msg_devtmpfs_fail:
    db 0x1B, '[1;31m', '[frOSt] FATAL: Cannot mount /dev', 0x1B, '[0m', 10, 0
msg_devtmpfs_fail_len equ $ - msg_devtmpfs_fail

msg_ram_prefix:
    db 0x1B, '[0;37m', '[frOSt] RAM: ', 0x1B, '[1;37m', 0
msg_ram_prefix_len equ $ - msg_ram_prefix

msg_mb_suffix:
    db ' MB', 0x1B, '[0m', 10, 0
msg_mb_suffix_len equ $ - msg_mb_suffix

msg_tmpfs_ok:
    db 0x1B, '[0;37m', '[frOSt] Transient overlay tmpfs mounted', 0x1B, '[0m', 10, 0
msg_tmpfs_ok_len equ $ - msg_tmpfs_ok

msg_scanning:
    db 0x1B, '[0;37m', '[frOSt] Scanning block devices...', 0x1B, '[0m', 10, 0
msg_scanning_len equ $ - msg_scanning

msg_dev_prefix:
    db '  -> /dev/', 0
msg_dev_prefix_len equ $ - msg_dev_prefix

msg_mdev:
    db 0x1B, '[0;37m', '[frOSt] mdev hotplug configured', 0x1B, '[0m', 10, 0
msg_mdev_len equ $ - msg_mdev

msg_newline:
    db 10

; ── Filesystem type strings ──
fs_proc:        db 'proc', 0
fs_sysfs:       db 'sysfs', 0
fs_devtmpfs:    db 'devtmpfs', 0
fs_tmpfs:       db 'tmpfs', 0

; ── Path strings ──
path_proc:      db '/proc', 0
path_sys:       db '/sys', 0
path_dev:       db '/dev', 0
path_frost:     db '/frost', 0
path_lower:     db '/frost/lower', 0
path_upper:     db '/frost/upper', 0
path_work:      db '/frost/work', 0
path_merged:    db '/frost/merged', 0
path_persist:   db '/frost/persist', 0
path_probe:     db '/frost/probe', 0
path_sys_block: db '/sys/block', 0
path_hotplug:   db '/proc/sys/kernel/hotplug', 0

; ── Device node paths ──
dev_console:    db '/dev/console', 0
dev_null:       db '/dev/null', 0
dev_zero:       db '/dev/zero', 0
dev_tty:        db '/dev/tty', 0

; ── mdev path for hotplug ──
mdev_path:      db '/bin/mdev', 0
mdev_path_len   equ $ - mdev_path

; ── tmpfs mount option prefix ──
tmpfs_size_prefix: db 'size=', 0

; =============================================================================
; BSS Section
; =============================================================================
section .bss
total_ram:      resq 1
