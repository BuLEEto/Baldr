package baldr

// glibc maps each large allocation (128 KB and up) and hands it back when it
// is freed, until the first such block is freed: then it raises that
// threshold to the freed block's size, and later blocks below it come from
// the heap and stay resident after they are freed. Every Odin thread frees
// its 4 MB scratch blocks when it ends, so the first finished job triggers
// it, and a startup that builds large transient tables (the GPU driver) can
// keep tens of megabytes it no longer uses. Setting the threshold
// explicitly turns the adjustment off, so the process keeps glibc's
// starting behaviour. A threshold the user chose (MALLOC_MMAP_THRESHOLD_,
// or the glibc.malloc.mmap_threshold tunable) is left alone; with another C
// library nothing happens.

import "core:dynlib"
import "core:os"
import "core:strings"

@(private)
M_MMAP_THRESHOLD :: -3

@(private)
GLIBC_MMAP_THRESHOLD :: 128 * 1024 // glibc's own starting value

@(private)
malloc_keep_large_blocks_mapped :: proc() {
	if os.get_env("MALLOC_MMAP_THRESHOLD_", context.temp_allocator) != "" do return
	if strings.contains(os.get_env("GLIBC_TUNABLES", context.temp_allocator), "mmap_threshold") do return
	lib, loaded := dynlib.load_library("libc.so.6")
	if !loaded do return
	ptr, found := dynlib.symbol_address(lib, "mallopt")
	if !found do return
	mallopt := (proc "c" (param: i32, value: i32) -> i32)(ptr)
	mallopt(M_MMAP_THRESHOLD, GLIBC_MMAP_THRESHOLD)
}
