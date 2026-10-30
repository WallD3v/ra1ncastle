#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/patches/linux/0002-t8030-android-write-allowlist.patch"
command -v cc >/dev/null 2>&1 || { echo "error: cc is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# These entry points cannot be reduced to the pure policy helper: verify the
# kernel patch retains its admin gates and filters every non-admin queue request.
admin_guard_count="$(grep -Fc 'NVME_F_NO_USER_ADMIN_PASSTHRU)' "$PATCH" || true)"
[[ "$admin_guard_count" == 4 ]] || {
	echo "FAIL: expected four admin passthrough gate uses, found $admin_guard_count" >&2
	exit 1
}
grep -Fq 'if (ctrl->ops->flags & NVME_F_NO_USER_ADMIN_PASSTHRU)' "$PATCH" || {
	echo 'FAIL: controller ioctl admin guard missing' >&2
	exit 1
}
grep -Fq 'if ((ctrl->ops->flags & NVME_F_NO_USER_ADMIN_PASSTHRU) &&' "$PATCH" || {
	echo 'FAIL: controller reset/admin ioctl guard missing' >&2
	exit 1
}
grep -Fq 'if (anv->write_allow_nranges && !q->is_adminq &&' "$PATCH" || {
	echo 'FAIL: non-admin block queue allowlist gate missing' >&2
	exit 1
}
printf 'PASS: admin ioctl/io_uring gates and block queue allowlist hooks present\n'

# Compile the exact LBA predicate, I/O policy, and DTB parser added by the
# kernel patch against minimal mock kernel/NVMe types. This validates their
# decisions without requiring an iPhone or a booted kernel.
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

awk -v function_name=apple_nvme_parse_write_allowlist '
  index($0, "+static int " function_name "(") == 1 { extracting = 1 }
  extracting {
    sub(/^\+/, "")
    opens = gsub(/\{/, "{")
    closes = gsub(/\}/, "}")
    depth += opens - closes
    print
    if (depth == 0 && opens + closes > 0) exit
  }
  END { if (!extracting || depth != 0) exit 1 }
' "$PATCH" > "$tmp/dtb-parser.c"

cat > "$tmp/test.c" <<'EOF'
#include <stdbool.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
#define ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof((a)[0])))

struct apple_nvme_lba_range { u64 first, last; };
struct device_node {
	bool has_nsid;
	bool has_ranges;
	u32 nsid;
	size_t ranges_bytes;
	u64 ranges[10];
	int nsid_error;
	int ranges_error;
};
struct device { struct device_node *of_node; };
struct apple_nvme {
	struct device *dev;
	u32 write_allow_nsid;
	u32 write_allow_nranges;
	struct apple_nvme_lba_range write_allow_ranges[APPLE_NVME_MAX_WRITE_RANGES];
};
struct property { int present; };
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

static int dev_err_probe(struct device *dev, int err, const char *fmt, ...)
{
	(void)dev;
	(void)fmt;
	return err;
}

static int of_property_count_elems_of_size(const struct device_node *np,
		const char *name, int elem_size)
{
	(void)name;
	if (!np->has_ranges)
		return -EINVAL;
	if (np->ranges_bytes % elem_size)
		return -EINVAL;
	return np->ranges_bytes / elem_size;
}

static struct property *of_find_property(const struct device_node *np,
		const char *name, int *length)
{
	(void)name;
	(void)length;
	if (!np->has_nsid)
		return NULL;
	static struct property property;
	return &property;
}

static int of_property_read_u32(const struct device_node *np,
		const char *name, u32 *value)
{
	(void)name;
	if (!np->has_nsid)
		return -EINVAL;
	if (np->nsid_error)
		return np->nsid_error;
	*value = np->nsid;
	return 0;
}

static int of_property_read_u64_array(const struct device_node *np,
		const char *name, u64 *values, int count)
{
	(void)name;
	if (np->ranges_error)
		return np->ranges_error;
	if (np->ranges_bytes < (size_t)count * sizeof(u64))
		return -EOVERFLOW;
	memcpy(values, np->ranges, (size_t)count * sizeof(u64));
	return 0;
}
EOF
cat "$tmp/predicate.c" >> "$tmp/test.c"
cat "$tmp/io-policy.c" >> "$tmp/test.c"
cat "$tmp/dtb-parser.c" >> "$tmp/test.c"
cat >> "$tmp/test.c" <<'EOF'

static int parse_contract(struct device_node node, struct apple_nvme *ctrl)
{
	struct device dev = {.of_node = &node};
	ctrl->dev = &dev;
	return apple_nvme_parse_write_allowlist(ctrl);
}

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
	struct device_node node;
	struct apple_nvme parsed;
	int ret;

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

	node = (struct device_node){0};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("both DTB properties absent selects read-only fallback", ret == 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_nsid = true, .has_ranges = true, .nsid = 1,
		.ranges_bytes = 2 * sizeof(u64), .ranges = {100, 199}};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("valid DTB contract accepted", ret == 0 && parsed.write_allow_nsid == 1 &&
		parsed.write_allow_nranges == 1 && parsed.write_allow_ranges[0].first == 100 &&
		parsed.write_allow_ranges[0].last == 199, true);

	node.has_nsid = false;
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("range without NSID fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_nsid = true, .nsid = 1};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("NSID without range fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_nsid = true, .has_ranges = true,
		.nsid = 1, .ranges_bytes = 2 * sizeof(u64), .ranges = {200, 199}};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("reversed range fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node.nsid = 0;
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("zero NSID fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_nsid = true, .has_ranges = true,
		.nsid = 1, .ranges_bytes = 10 * sizeof(u64)};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("too many ranges fail closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_nsid = true, .has_ranges = true,
		.nsid = 1, .ranges_bytes = 8 * sizeof(u64),
		.ranges = {0, 1, 3, 4, 6, 7, 9, 10}};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("maximum supported range count accepted", ret == 0 &&
		parsed.write_allow_nranges == APPLE_NVME_MAX_WRITE_RANGES, true);

	node.ranges_bytes = 0;
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("empty range property fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_nsid = true, .has_ranges = true,
		.nsid = 1, .ranges_bytes = 2 * sizeof(u64), .ranges_error = -EIO,
		.ranges = {100, 199}};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("DTB read failure fails closed", ret == -EIO && parsed.write_allow_nranges == 0, true);

	node.ranges_bytes = 3 * sizeof(u64);
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("odd range cell count fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node.ranges_bytes = sizeof(u64) + 1;
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("malformed property length fails closed", ret < 0 && parsed.write_allow_nranges == 0, true);

	node = (struct device_node){.has_ranges = true,
		.ranges_bytes = sizeof(u64) + 1};
	parsed = (struct apple_nvme){0};
	ret = parse_contract(node, &parsed);
	check("malformed range without NSID remains read-only", ret == 0 &&
		parsed.write_allow_nranges == 0, true);
	return 0;
}
EOF

cc -std=c11 -Wall -Wextra -Werror -O2 "$tmp/test.c" -o "$tmp/test"
"$tmp/test"
