package launchd

import (
	"syscall"
	"unsafe"
)

// The libSystem calls go through the runtime's libc trampolines, as golang.org/x/sys/unix does, so no cgo is needed.

//go:linkname syscall_syscall syscall.syscall
func syscall_syscall(fn, a1, a2, a3 uintptr) (r1, r2 uintptr, err syscall.Errno)

var libc_launch_activate_socket_trampoline_addr uintptr

//go:cgo_import_dynamic libc_launch_activate_socket launch_activate_socket "/usr/lib/libSystem.B.dylib"

var libc_free_trampoline_addr uintptr

//go:cgo_import_dynamic libc_free free "/usr/lib/libSystem.B.dylib"

// activate calls launch_activate_socket(3), which returns an errno value rather than setting errno.
func activate(name string) ([]int32, error) {
	cname, err := syscall.BytePtrFromString(name)
	if err != nil {
		return nil, err
	}
	var fds *int32
	var count uintptr
	r1, _, _ := syscall_syscall(libc_launch_activate_socket_trampoline_addr,
		uintptr(unsafe.Pointer(cname)), uintptr(unsafe.Pointer(&fds)), uintptr(unsafe.Pointer(&count)))
	if r1 != 0 {
		return nil, syscall.Errno(r1)
	}
	if fds == nil {
		return nil, nil
	}
	out := append([]int32(nil), unsafe.Slice(fds, count)...)
	syscall_syscall(libc_free_trampoline_addr, uintptr(unsafe.Pointer(fds)), 0, 0)
	return out, nil
}
