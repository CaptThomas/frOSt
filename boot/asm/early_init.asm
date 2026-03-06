; =============================================================================
; frOSt Early Init - x86-64 Assembly
; =============================================================================
; Bare-metal early boot stub, runs before shell bootstrap + Python init.
; No libc, pure Linux syscalls.
;
; Responsibilities:
;   1. Mount /proc, /sys, /dev (devtmpfs)
;   2. Detect kernel version (for module paths)
;   3. Detect RAM, calculate tmpfs size
;   4. Create overlay directory structure
;   5. Mount tmpfs for transient overlay layer
;   6. Set up /dev/console, /dev/null, /dev/zero, /dev/tty
;   7. Configure kernel hotplug for mdev
;   8. Load critical kernel modules via finit_module(2)
;   9. Scan /sys/block and report block devices
;  10. Exit 0 -> hand off to shell bootstrap -> Python frost_init
; =============================================================================

BITS 64

section .text
global _start

; ── Syscall numbers (x86-64 Linux) ──
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_uname       63
%define SYS_mkdir       83
%define SYS_sysinfo     99
%define SYS_mknod       133
%define SYS_mount       165
%define SYS_getdents64  217
%define SYS_finit_module 313
%define SYS_exit        60

; ── Mount flags ──
%define MS_NOSUID       2
%define MS_NOEXEC       8

; ── Open flags ──
%define O_RDONLY        0
%define O_WRONLY        1
%define O_CLOEXEC       0x80000

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
    lea     rdi, [rel fs_proc]
    lea     rsi, [rel path_proc]
    lea     rdx, [rel fs_proc]
    xor     r10d, r10d
    xor     r8d, r8d
    call    do_mount
    test    eax, eax
    jnz     .fail_proc

    lea     rdi, [rel fs_sysfs]
    lea     rsi, [rel path_sys]
    lea     rdx, [rel fs_sysfs]
    xor     r10d, r10d
    xor     r8d, r8d
    call    do_mount
    test    eax, eax
    jnz     .fail_sysfs

    lea     rdi, [rel fs_devtmpfs]
    lea     rsi, [rel path_dev]
    lea     rdx, [rel fs_devtmpfs]
    mov     r10d, MS_NOSUID | MS_NOEXEC
    xor     r8d, r8d
    call    do_mount
    test    eax, eax
    jnz     .fail_devtmpfs

    ; ── Step 2: Detect kernel version ──
    call    detect_kver

    ; ── Step 3: Detect RAM ──
    call    detect_memory

    ; ── Step 4: Create overlay directories ──
    call    create_overlay_dirs

    ; ── Step 5: Mount tmpfs overlay ──
    call    mount_tmpfs_overlay

    ; ── Step 6: Create essential device nodes ──
    call    create_dev_nodes

    ; ── Step 7: Configure mdev hotplug ──
    call    setup_mdev

    ; ── Step 8: Load critical kernel modules ──
    call    load_modules

    ; ── Step 9: Scan block devices ──
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
; Generic mount: mkdir target then mount(source, target, fstype, flags, data)
; Args: rdi=source, rsi=target, rdx=fstype, r10=flags, r8=data
; Returns: mount result in eax (0=success, negative=-errno)
; =============================================================================
do_mount:
    push    rdi
    push    rsi
    push    rdx
    push    r10
    push    r8
    mov     rdi, rsi                    ; mkdir(target, 0755)
    mov     esi, 0o755
    mov     eax, SYS_mkdir
    syscall                             ; ignore result (EEXIST is fine)
    pop     r8
    pop     r10
    pop     rdx
    pop     rsi
    pop     rdi
    mov     eax, SYS_mount
    syscall
    ret

; =============================================================================
; Detect kernel version via uname(2)
; Stores release string in kver_buf, builds module base path in modpath_buf
; =============================================================================
detect_kver:
    push    rbx
    sub     rsp, 400                    ; struct utsname = 6 * 65 = 390, pad to 400

    lea     rdi, [rsp]
    mov     eax, SYS_uname
    syscall
    test    eax, eax
    jnz     .kver_fail

    ; release is at offset 130 (after sysname[65] + nodename[65])
    lea     rsi, [rsp + 130]

    ; Copy release to kver_buf
    lea     rdi, [rel kver_buf]
    xor     ecx, ecx
.kver_copy:
    mov     al, [rsi + rcx]
    mov     [rdi + rcx], al
    test    al, al
    jz      .kver_done
    inc     ecx
    cmp     ecx, 64
    jl      .kver_copy
    mov     byte [rdi + rcx], 0         ; ensure null-terminated
.kver_done:
    mov     [rel kver_len], cl

    ; Build "/lib/modules/<kver>/kernel/" in modpath_buf
    lea     rdi, [rel modpath_buf]
    lea     rsi, [rel modpath_prefix]   ; "/lib/modules/"
.mp_cp1:
    lodsb
    test    al, al
    jz      .mp_kver
    stosb
    jmp     .mp_cp1
.mp_kver:
    lea     rsi, [rel kver_buf]
.mp_cp2:
    lodsb
    test    al, al
    jz      .mp_suffix
    stosb
    jmp     .mp_cp2
.mp_suffix:
    mov     dword [rdi], '/ker'
    add     rdi, 4
    mov     dword [rdi], 'nel/'
    add     rdi, 4
    mov     byte [rdi], 0

    ; Save modpath length
    lea     rax, [rel modpath_buf]
    sub     rdi, rax
    mov     [rel modpath_len], edi

    ; Print kernel version
    mov     rdi, STDOUT
    lea     rsi, [rel msg_kver_prefix]
    mov     rdx, msg_kver_prefix_len
    call    sys_write

    movzx   edx, byte [rel kver_len]
    lea     rsi, [rel kver_buf]
    mov     rdi, STDOUT
    call    sys_write

    mov     rdi, STDOUT
    lea     rsi, [rel msg_newline]
    mov     rdx, 1
    call    sys_write

    add     rsp, 400
    pop     rbx
    ret

.kver_fail:
    mov     byte [rel kver_buf], 0
    mov     byte [rel kver_len], 0
    add     rsp, 400
    pop     rbx
    ret

; =============================================================================
; Detect total system memory via sysinfo(2)
; =============================================================================
detect_memory:
    push    rbx
    sub     rsp, 128                    ; struct sysinfo

    lea     rdi, [rsp]
    mov     eax, SYS_sysinfo
    syscall
    test    eax, eax
    jnz     .mem_fail

    ; struct sysinfo x86-64 offsets:
    ;   +32: totalram (unsigned long)
    ;   +104: mem_unit (unsigned int)
    mov     rax, [rsp + 32]
    mov     ecx, [rsp + 104]
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

    add     rsp, 128
    pop     rbx
    ret

.mem_fail:
    mov     rax, 512 * 1024 * 1024      ; default 512 MB
    mov     [rel total_ram], rax
    add     rsp, 128
    pop     rbx
    ret

; =============================================================================
; Create overlay directory tree
; =============================================================================
create_overlay_dirs:
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
    ret

; =============================================================================
; Mount tmpfs for transient overlay layer (50% of RAM, min 512M)
; =============================================================================
mount_tmpfs_overlay:
    push    rbx
    sub     rsp, 64

    ; Calculate 50% of RAM in MB
    mov     rax, [rel total_ram]
    shr     rax, 21                     ; bytes / 2 / 1048576 = 50% in MB
    cmp     rax, 512
    jge     .tmpfs_size_ok
    mov     eax, 512
.tmpfs_size_ok:
    mov     rbx, rax                    ; save size

    ; Build "size=XXXM" on stack
    lea     rdi, [rsp]
    mov     dword [rdi], 'size'
    mov     byte [rdi+4], '='
    add     rdi, 5

    mov     rax, rbx
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
; Create essential device nodes (data-driven)
; =============================================================================
create_dev_nodes:
    push    rbx
    push    r12
    lea     r12, [rel devnode_table]
.devnode_loop:
    mov     rdi, [r12]                  ; path pointer
    test    rdi, rdi
    jz      .devnode_done
    mov     esi, [r12 + 8]              ; mode
    mov     edx, [r12 + 12]             ; dev number
    mov     eax, SYS_mknod
    syscall
    add     r12, 16                     ; next entry
    jmp     .devnode_loop
.devnode_done:
    pop     r12
    pop     rbx
    ret

; =============================================================================
; Set up mdev as hotplug handler
; =============================================================================
setup_mdev:
    push    rbx

    lea     rdi, [rel path_hotplug]
    mov     esi, O_WRONLY
    mov     eax, SYS_open
    syscall
    test    eax, eax
    js      .mdev_done
    mov     ebx, eax

    mov     edi, ebx
    lea     rsi, [rel mdev_path]
    mov     edx, mdev_path_len
    mov     eax, SYS_write
    syscall

    mov     edi, ebx
    mov     eax, SYS_close
    syscall

.mdev_done:
    mov     rdi, STDOUT
    lea     rsi, [rel msg_mdev]
    mov     rdx, msg_mdev_len
    call    sys_write

    pop     rbx
    ret

; =============================================================================
; Load critical kernel modules via finit_module(2)
;
; Iterates a null-terminated table of relative .ko paths and loads each via:
;   fd = open("/lib/modules/<kver>/kernel/<path>", O_RDONLY|O_CLOEXEC)
;   finit_module(fd, "", 0)
;   close(fd)
;
; Falls back to .ko.xz extension if .ko not found (kernel decompresses).
; Silently ignores failures (builtin or missing modules).
; =============================================================================
load_modules:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Skip if kver detection failed
    cmp     byte [rel kver_buf], 0
    je      .lm_skip

    mov     rdi, STDOUT
    lea     rsi, [rel msg_loading_mods]
    mov     rdx, msg_loading_mods_len
    call    sys_write

    xor     r15d, r15d                  ; loaded count
    lea     r14, [rel mod_table]        ; current table entry

.lm_next_entry:
    cmp     byte [r14], 0               ; end of table?
    je      .lm_print_count

    ; Build full path: modpath_buf + current entry -> pathbuild_buf
    lea     rdi, [rel pathbuild_buf]
    lea     rsi, [rel modpath_buf]
    mov     ecx, [rel modpath_len]
    rep     movsb                       ; fast copy of known-length base path
    mov     rsi, r14
.lm_cp_rel_loop:
    lodsb
    stosb                               ; copy including null terminator
    test    al, al
    jnz     .lm_cp_rel_loop
    mov     r12, rsi                    ; r12 -> next table entry

    ; Try open .ko
    lea     rdi, [rel pathbuild_buf]
    mov     esi, O_RDONLY | O_CLOEXEC
    mov     eax, SYS_open
    syscall
    test    eax, eax
    jns     .lm_finit

    ; Try .ko.xz: find the null terminator and append .xz
    lea     rdi, [rel pathbuild_buf]
    xor     ecx, ecx
.lm_find_end:
    cmp     byte [rdi + rcx], 0
    je      .lm_append_xz
    inc     ecx
    jmp     .lm_find_end
.lm_append_xz:
    mov     byte [rdi + rcx], '.'
    mov     byte [rdi + rcx + 1], 'x'
    mov     byte [rdi + rcx + 2], 'z'
    mov     byte [rdi + rcx + 3], 0

    lea     rdi, [rel pathbuild_buf]
    mov     esi, O_RDONLY | O_CLOEXEC
    mov     eax, SYS_open
    syscall
    test    eax, eax
    js      .lm_advance                 ; not found, skip

.lm_finit:
    mov     ebx, eax                    ; save fd
    mov     edi, eax                    ; fd
    lea     rsi, [rel mod_empty_params] ; ""
    xor     edx, edx                    ; flags=0
    mov     eax, SYS_finit_module
    syscall
    mov     r13d, eax                   ; save result

    mov     edi, ebx                    ; close fd
    mov     eax, SYS_close
    syscall

    test    r13d, r13d
    jnz     .lm_advance
    inc     r15d                        ; success

.lm_advance:
    mov     r14, r12
    jmp     .lm_next_entry

.lm_print_count:
    mov     rdi, STDOUT
    lea     rsi, [rel msg_mod_prefix]
    mov     rdx, msg_mod_prefix_len
    call    sys_write

    mov     eax, r15d
    call    print_decimal

    mov     rdi, STDOUT
    lea     rsi, [rel msg_mod_suffix]
    mov     rdx, msg_mod_suffix_len
    call    sys_write

.lm_skip:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; Detect block devices by scanning /sys/block
; =============================================================================
detect_block_devices:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
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
    mov     r12d, eax                   ; fd
    lea     r13, [rsp]                  ; buffer base (callee-saved)

.read_loop:
    mov     edi, r12d
    mov     rsi, r13
    mov     edx, 1088
    mov     eax, SYS_getdents64
    syscall
    test    eax, eax
    jle     .close_dir

    mov     r14d, eax                   ; total bytes (callee-saved)
    xor     ebx, ebx                    ; current offset (callee-saved)
.next_ent:
    cmp     ebx, r14d
    jge     .read_loop

    ; linux_dirent64: d_reclen at +16, d_name at +19
    movzx   r15d, word [r13 + rbx + 16] ; d_reclen (callee-saved, survives calls)

    ; Skip . and ..
    cmp     byte [r13 + rbx + 19], '.'
    je      .skip_ent
    ; Skip loop*
    cmp     byte [r13 + rbx + 19], 'l'
    jne     .not_loop
    cmp     byte [r13 + rbx + 20], 'o'
    je      .skip_ent
.not_loop:
    ; Skip ram*
    cmp     byte [r13 + rbx + 19], 'r'
    jne     .print_dev
    cmp     byte [r13 + rbx + 20], 'a'
    je      .skip_ent

.print_dev:
    ; Print "  -> /dev/<name>\n"
    mov     rdi, STDOUT
    lea     rsi, [rel msg_dev_prefix]
    mov     rdx, msg_dev_prefix_len
    call    sys_write

    lea     rsi, [r13 + rbx + 19]       ; d_name (r13, rbx callee-saved)
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

.skip_ent:
    add     ebx, r15d
    jmp     .next_ent

.close_dir:
    mov     edi, r12d
    mov     eax, SYS_close
    syscall
.scan_done:
    add     rsp, 1088
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; =============================================================================
; Utility: sys_write(rdi=fd, rsi=buf, rdx=len)
; =============================================================================
sys_write:
    mov     eax, SYS_write
    syscall
    ret

; =============================================================================
; Utility: print unsigned decimal (rax) to stdout
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
    mov     rsi, rdi
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
; Data Section - no trailing null bytes in length calculations
; =============================================================================
section .data

; ── Boot banner ──
msg_banner:
    db 10
    db 0x1B, '[1;34m'
    db '   +-------------------------------------------------+', 10
    db '   |', 0x1B, '[1;36m'
    db '  *  frOSt Kernel Bootstrap  *                  ', 0x1B, '[1;34m', '|', 10
    db '   +-------------------------------------------------+', 10
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
    db '  ------------------------------------------', 10
msg_banner_len equ $ - msg_banner

msg_done:
    db 0x1B, '[1;32m', '[frOSt] Assembly init complete -> shell bootstrap', 0x1B, '[0m', 10
msg_done_len equ $ - msg_done

msg_proc_fail:
    db 0x1B, '[1;31m', '[frOSt] FATAL: Cannot mount /proc', 0x1B, '[0m', 10
msg_proc_fail_len equ $ - msg_proc_fail

msg_sysfs_fail:
    db 0x1B, '[1;31m', '[frOSt] FATAL: Cannot mount /sys', 0x1B, '[0m', 10
msg_sysfs_fail_len equ $ - msg_sysfs_fail

msg_devtmpfs_fail:
    db 0x1B, '[1;31m', '[frOSt] FATAL: Cannot mount /dev', 0x1B, '[0m', 10
msg_devtmpfs_fail_len equ $ - msg_devtmpfs_fail

msg_ram_prefix:
    db 0x1B, '[0;37m', '[frOSt] RAM: ', 0x1B, '[1;37m'
msg_ram_prefix_len equ $ - msg_ram_prefix

msg_mb_suffix:
    db ' MB', 0x1B, '[0m', 10
msg_mb_suffix_len equ $ - msg_mb_suffix

msg_tmpfs_ok:
    db 0x1B, '[0;37m', '[frOSt] Transient overlay tmpfs mounted', 0x1B, '[0m', 10
msg_tmpfs_ok_len equ $ - msg_tmpfs_ok

msg_scanning:
    db 0x1B, '[0;37m', '[frOSt] Scanning block devices...', 0x1B, '[0m', 10
msg_scanning_len equ $ - msg_scanning

msg_dev_prefix:
    db '  -> /dev/'
msg_dev_prefix_len equ $ - msg_dev_prefix

msg_mdev:
    db 0x1B, '[0;37m', '[frOSt] mdev hotplug configured', 0x1B, '[0m', 10
msg_mdev_len equ $ - msg_mdev

msg_kver_prefix:
    db 0x1B, '[0;37m', '[frOSt] Kernel: ', 0x1B, '[1;37m'
msg_kver_prefix_len equ $ - msg_kver_prefix

msg_loading_mods:
    db 0x1B, '[0;37m', '[frOSt] Loading kernel modules (asm)...', 0x1B, '[0m', 10
msg_loading_mods_len equ $ - msg_loading_mods

msg_mod_prefix:
    db 0x1B, '[1;32m', '[frOSt]', 0x1B, '[0m', ' '
msg_mod_prefix_len equ $ - msg_mod_prefix

msg_mod_suffix:
    db ' modules loaded (asm fast-path)', 10
msg_mod_suffix_len equ $ - msg_mod_suffix

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

; ── Module path prefix ──
modpath_prefix: db '/lib/modules/', 0

; ── Device node paths ──
dev_console:    db '/dev/console', 0
dev_null:       db '/dev/null', 0
dev_zero:       db '/dev/zero', 0
dev_tty:        db '/dev/tty', 0

; ── mdev path (length excludes null terminator) ──
mdev_path:      db '/bin/mdev'
mdev_path_len   equ $ - mdev_path
                db 0

; ── Empty params for finit_module ──
mod_empty_params: db 0

; ── Device node table: [ptr, mode, dev] entries, null-terminated ──
devnode_table:
    dq dev_console
    dd S_IFCHR | 0o622, (5 << 8) | 1
    dq dev_null
    dd S_IFCHR | 0o666, (1 << 8) | 3
    dq dev_zero
    dd S_IFCHR | 0o666, (1 << 8) | 5
    dq dev_tty
    dd S_IFCHR | 0o666, (5 << 8) | 0
    dq 0                                ; sentinel

; =============================================================================
; Module table: relative paths under /lib/modules/<kver>/kernel/
; Null-terminated entries. Table ends with a lone 0 byte.
; Dependency order: load prerequisites before dependents.
; =============================================================================
mod_table:
    ; -- SCSI / ATA core --
    db 'drivers/scsi/scsi_common.ko', 0
    db 'drivers/scsi/scsi_mod.ko', 0
    db 'block/t10-pi.ko', 0
    db 'crypto/crct10dif_common.ko', 0
    db 'crypto/crct10dif_generic.ko', 0
    db 'lib/crc-t10dif.ko', 0
    db 'crypto/crc32c_generic.ko', 0
    db 'lib/crc64-rocksoft.ko', 0
    db 'drivers/scsi/sd_mod.ko', 0
    db 'drivers/scsi/sg.ko', 0
    db 'drivers/ata/libata.ko', 0
    db 'drivers/ata/ata_piix.ko', 0
    db 'drivers/ata/ata_generic.ko', 0
    db 'drivers/ata/libahci.ko', 0
    db 'drivers/ata/ahci.ko', 0
    ; -- VirtIO (QEMU) --
    db 'drivers/virtio/virtio.ko', 0
    db 'drivers/virtio/virtio_ring.ko', 0
    db 'drivers/virtio/virtio_pci.ko', 0
    db 'drivers/virtio/virtio_pci_modern_dev.ko', 0
    db 'drivers/virtio/virtio_pci_legacy_dev.ko', 0
    db 'drivers/block/virtio_blk.ko', 0
    db 'drivers/scsi/virtio_scsi.ko', 0
    db 'drivers/net/virtio_net.ko', 0
    ; -- USB stack --
    db 'drivers/usb/common/usb-common.ko', 0
    db 'drivers/usb/core/usbcore.ko', 0
    db 'drivers/usb/host/xhci-hcd.ko', 0
    db 'drivers/usb/host/xhci-pci.ko', 0
    db 'drivers/usb/host/ehci-hcd.ko', 0
    db 'drivers/usb/host/ehci-pci.ko', 0
    db 'drivers/usb/storage/usb-storage.ko', 0
    ; -- Filesystems --
    db 'fs/jbd2/jbd2.ko', 0
    db 'fs/mbcache.ko', 0
    db 'lib/crc16.ko', 0
    db 'fs/ext4/ext4.ko', 0
    db 'fs/squashfs/squashfs.ko', 0
    db 'fs/overlayfs/overlay.ko', 0
    db 'drivers/block/loop.ko', 0
    db 'fs/fat/fat.ko', 0
    db 'fs/fat/vfat.ko', 0
    db 'fs/nls/nls_cp437.ko', 0
    db 'fs/nls/nls_utf8.ko', 0
    db 'fs/nls/nls_ascii.ko', 0
    ; -- HID --
    db 'drivers/hid/hid.ko', 0
    db 'drivers/hid/usbhid/usbhid.ko', 0
    db 'drivers/hid/hid-generic.ko', 0
    ; -- DRM --
    db 'drivers/gpu/drm/drm.ko', 0
    db 'drivers/gpu/drm/drm_kms_helper.ko', 0
    db 'drivers/gpu/drm/tiny/bochs.ko', 0
    db 'drivers/gpu/drm/virtio/virtio-gpu.ko', 0
    ; -- End --
    db 0


; =============================================================================
; BSS Section
; =============================================================================
section .bss
total_ram:      resq 1
kver_buf:       resb 65
kver_len:       resb 1
modpath_buf:    resb 256
modpath_len:    resd 1
pathbuild_buf:  resb 512