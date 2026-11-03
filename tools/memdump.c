/* memdump ADDR LEN: physical memory to stdout through mmap of /dev/mem (on the MiSTer: the
 * core's DDR3, e.g. the TGA's VRAM at 0x30100000; tools/vram2png.py renders it). */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: memdump ADDR LEN\n"); return 2; }
	unsigned long a = strtoul(argv[1], 0, 0), n = strtoul(argv[2], 0, 0);
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	unsigned long base = a & ~0xFFFUL, off = a - base;
	unsigned char *p = mmap(0, n + off, PROT_READ, MAP_SHARED, fd, base);
	if (p == MAP_FAILED) { perror("mmap"); return 1; }
	fwrite(p + off, 1, n, stdout);
	return 0;
}
