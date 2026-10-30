#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/patches/linux/0002-t8030-android-write-allowlist.patch"
command -v cc >/dev/null 2>&1 || { echo "error: cc is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Compile the exact predicate added by the kernel patch against minimal mock
# NVMe types. This validates the driver's inclusive-LBA and overflow logic
# without requiring an iPhone or a booted kernel.
awk '
  /^\+static bool apple_nvme_write_allowed\(/ { extracting = 1 }
  extracting {
    sub(/^\+/, "")
    opens = gsub(/\{/, "{")
    closes = gsub(/\}/, "}")
    depth += opens - closes
    print
    if (depth == 0 && opens + closes > 0) exit
  }
  END { if (!extracting || depth != 0) exit 1 }
' "$PATCH" > "$tmp/predicate.c"

awk -v function_name=apple_nvme_io_allowed '
  index($0, "+static bool " function_name "(") == 1 { extracting = 1 }
  extracting {
    sub(/^\+/, "")
    opens = gsub(/\{/, "{")
    closes = gsub(/\}/, "}")
    depth += opens - closes
    print
    if (depth == 0 && opens + closes > 0) exit
  }
  END { if (!extracting || depth != 0) exit 1 }
' "$PATCH" > "$tmp/io-policy.c"

cat > "$tmp/test.c" <<'EOF'
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef uint16_t __le16;
typedef uint64_t __le64;
#define le64_to_cpu(v) (v)
#define le16_to_cpu(v) (v)
#define APPLE_NVME_MAX_WRITE_RANGES 4
#define nvme_cmd_write 0x01
#define nvme_cmd_read 0x02
#define nvme_cmd_flush 0x00

struct apple_nvme_lba_range { u64 first, last; };
struct apple_nvme {
	u32 write_allow_nsid;
	u32 write_allow_nranges;
	struct apple_nvme_lba_range write_allow_ranges[APPLE_NVME_MAX_WRITE_RANGES];
};
struct nvme_ns_head { u32 ns_id; };
struct nvme_ns { struct nvme_ns_head *head; };
struct nvme_rw_command { __le64 slba; __le16 length; };
struct nvme_command {
	struct { uint8_t opcode; } common;
	struct nvme_rw_command rw;
};

static void check(const char *name, bool got, bool expected)
{
	if (got != expected) {
		fprintf(stderr, "FAIL: %s (got %d, expected %d)\n", name, got, expected);
		exit(1);
	}
	printf("PASS: %s\n", name);
}
EOF
cat "$tmp/predicate.c" >> "$tmp/test.c"
cat "$tmp/io-policy.c" >> "$tmp/test.c"
cat >> "$tmp/test.c" <<'EOF'

int main(void)
{
	struct apple_nvme ctrl = {
		.write_allow_nsid = 1,
		.write_allow_nranges = 2,
		.write_allow_ranges = {{100, 199}, {300, 399}},
	};
	struct nvme_ns_head head = {.ns_id = 1};
	struct nvme_ns ns = {.head = &head};
	struct nvme_rw_command rw;
	struct nvme_command cmd;

	rw = (struct nvme_rw_command){.slba = 100, .length = 0};
	check("first allowed LBA, one block", apple_nvme_write_allowed(&ctrl, &ns, &rw), true);
	rw = (struct nvme_rw_command){.slba = 199, .length = 0};
	check("last allowed LBA, one block", apple_nvme_write_allowed(&ctrl, &ns, &rw), true);
	rw = (struct nvme_rw_command){.slba = 100, .length = 99};
	check("full inclusive range", apple_nvme_write_allowed(&ctrl, &ns, &rw), true);
	rw = (struct nvme_rw_command){.slba = 300, .length = 99};
	check("second allowlisted range", apple_nvme_write_allowed(&ctrl, &ns, &rw), true);
	rw = (struct nvme_rw_command){.slba = 99, .length = 1};
	check("request starts before range", apple_nvme_write_allowed(&ctrl, &ns, &rw), false);
	rw = (struct nvme_rw_command){.slba = 199, .length = 1};
	check("request crosses range end", apple_nvme_write_allowed(&ctrl, &ns, &rw), false);
	rw = (struct nvme_rw_command){.slba = 200, .length = 0};
	check("one past range end", apple_nvme_write_allowed(&ctrl, &ns, &rw), false);
	rw = (struct nvme_rw_command){.slba = 250, .length = 0};
	check("gap between ranges", apple_nvme_write_allowed(&ctrl, &ns, &rw), false);
	head.ns_id = 2;
	rw = (struct nvme_rw_command){.slba = 100, .length = 0};
	check("wrong namespace", apple_nvme_write_allowed(&ctrl, &ns, &rw), false);
	head.ns_id = 1;
	rw = (struct nvme_rw_command){.slba = UINT64_MAX, .length = 1};
	check("LBA arithmetic overflow", apple_nvme_write_allowed(&ctrl, &ns, &rw), false);

	cmd = (struct nvme_command){.common.opcode = nvme_cmd_read};
	head.ns_id = 9;
	check("read allowed for other namespace", apple_nvme_io_allowed(&ctrl, &ns, &cmd), true);
	head.ns_id = 1;
	cmd = (struct nvme_command){.common.opcode = nvme_cmd_write,
		.rw = {.slba = 199, .length = 0}};
	check("write accepted at final allowlisted LBA", apple_nvme_io_allowed(&ctrl, &ns, &cmd), true);
	cmd.rw = (struct nvme_rw_command){.slba = 199, .length = 1};
	check("write crossing allowlist denied", apple_nvme_io_allowed(&ctrl, &ns, &cmd), false);
	cmd = (struct nvme_command){.common.opcode = nvme_cmd_flush};
	check("flush accepted for allowlisted namespace", apple_nvme_io_allowed(&ctrl, &ns, &cmd), true);
	head.ns_id = 9;
	check("flush denied for other namespace", apple_nvme_io_allowed(&ctrl, &ns, &cmd), false);
	cmd = (struct nvme_command){.common.opcode = 0x09};
	check("dataset management rejected", apple_nvme_io_allowed(&ctrl, &ns, &cmd), false);
	cmd = (struct nvme_command){.common.opcode = 0x08};
	check("write zeroes rejected", apple_nvme_io_allowed(&ctrl, &ns, &cmd), false);
	cmd = (struct nvme_command){.common.opcode = 0xff};
	check("unknown I/O opcode rejected", apple_nvme_io_allowed(&ctrl, &ns, &cmd), false);
	return 0;
}
EOF

cc -std=c11 -Wall -Wextra -Werror -O2 "$tmp/test.c" -o "$tmp/test"
"$tmp/test"
