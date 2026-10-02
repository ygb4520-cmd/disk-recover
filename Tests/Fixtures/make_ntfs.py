#!/usr/bin/env python3
"""Builds a small synthetic NTFS volume (no index trees — just a valid boot sector, $MFT, $Bitmap and file records)
that exercises the Disk Recover NTFS reader: update-sequence fixups, fragmented runlists, resident data,
$ATTRIBUTE_LIST with an extension record, deleted files, a deleted directory with a deleted child, and an orphan.

usage: make_ntfs.py out.img manifest.json
"""
import json, hashlib, os, random, struct, sys

random.seed(1234)
BPS, SPC = 512, 8
CS = BPS * SPC
TOTAL_SECTORS = 16384            # 8 MiB volume (incl. the backup boot sector in the last one)
NCLUST = TOTAL_SECTORS * BPS // CS
REC = 1024
MFT_CLUSTER = 4
NREC = 32

img = bytearray(TOTAL_SECTORS * BPS)
bitmap = bytearray((NCLUST + 7) // 8)
def alloc(c0, n):
    for c in range(c0, c0 + n): bitmap[c // 8] |= 1 << (c % 8)
alloc(0, 16)                       # boot area, MFT, bitmap file

def nttime(): return 133_000_000_000_000_000 + random.randrange(10**9)

def u16(v): return struct.pack('<H', v)
def u32(v): return struct.pack('<I', v)
def u64(v): return struct.pack('<Q', v)
def pad8(b): return b + b'\0' * (-len(b) % 8)

def enc_runs(runs):
    """runs: list of (lcn or None for sparse, length)"""
    out = b''; prev = 0
    for lcn, ln in runs:
        lb = max(1, (ln.bit_length() + 7) // 8)
        if lcn is None:
            out += bytes([lb]) + ln.to_bytes(lb, 'little'); continue
        d = lcn - prev; prev = lcn
        ob = 1
        while True:
            try: d.to_bytes(ob, 'little', signed=True); break
            except OverflowError: ob += 1
        out += bytes([(ob << 4) | lb]) + ln.to_bytes(lb, 'little') + d.to_bytes(ob, 'little', signed=True)
    return out + b'\0'

def attr_res(atype, content, name='', aid=0):
    nm = name.encode('utf-16-le')
    nameoff = 0x18
    contentoff = nameoff + len(nm)
    contentoff += -contentoff % 8
    body = u32(atype) + u32(0) + b'\0' + bytes([len(name)]) + u16(nameoff) + u16(0) + u16(aid)
    body += u32(len(content)) + u16(contentoff) + b'\0\0'
    body += nm + b'\0' * (contentoff - 0x18 - len(nm)) + content
    body = pad8(body)
    return body[:4] + u32(len(body)) + body[8:]

def attr_nonres(atype, runs, real, start_vcn=0, last_vcn=None, name='', aid=0, flags=0):
    nm = name.encode('utf-16-le')
    r = enc_runs(runs)
    clusters = sum(l for _, l in runs)
    if last_vcn is None: last_vcn = start_vcn + clusters - 1
    nameoff = 0x40
    runoff = nameoff + len(nm); runoff += -runoff % 8
    h = u32(atype) + u32(0) + b'\1' + bytes([len(name)]) + u16(nameoff) + u16(flags) + u16(aid)
    h += u64(start_vcn) + u64(last_vcn) + u16(runoff) + u16(0) + b'\0\0\0\0'
    h += u64(clusters * CS) + u64(real) + u64(real)
    h += nm + b'\0' * (runoff - 0x40 - len(nm)) + r
    h = pad8(h)
    return h[:4] + u32(len(h)) + h[8:]

def std_info():
    t = nttime()
    return attr_res(0x10, u64(t) * 1 + u64(t) + u64(t) + u64(t) + u32(0) + b'\0' * 12)

def file_name(parent, parent_seq, name, size, is_dir, ns=1):
    t = nttime()
    c = u64(parent | (parent_seq << 48)) + u64(t) * 4 + u64(size) + u64(size) + u32(0x10000000 if is_dir else 0) + u32(0)
    c += bytes([len(name), ns]) + name.encode('utf-16-le')
    return attr_res(0x30, c)

def make_record(num, seq, in_use, is_dir, attrs, base=0):
    h = bytearray(REC)
    h[0:4] = b'FILE'
    h[4:6] = u16(0x30); h[6:8] = u16(3)
    h[16:18] = u16(seq); h[18:20] = u16(1)
    h[20:22] = u16(0x38)
    h[22:24] = u16((1 if in_use else 0) | (2 if is_dir else 0))
    body = b''.join(attrs) + u32(0xFFFFFFFF) + u32(0)
    used = 0x38 + len(body)
    assert used <= REC, (num, used)
    h[24:28] = u32(used); h[28:32] = u32(REC)
    h[32:40] = u64(base)
    h[40:42] = u16(len(attrs) + 1)
    h[44:48] = u32(num)
    h[0x38:0x38 + len(body)] = body
    # fixups
    usn = 0x0001
    h[0x30:0x32] = u16(usn)
    for i in (1, 2):
        pos = i * 512 - 2
        h[0x30 + 2 * i:0x32 + 2 * i] = h[pos:pos + 2]
        h[pos:pos + 2] = u16(usn)
    return bytes(h)

records = {}
manifest = {'files': {}}

def put_data(c0, data):
    off = c0 * CS
    img[off:off + len(data)] = data

def sha(b): return hashlib.sha256(b).hexdigest()

# --- file contents
hello = b'Hello from a resident NTFS file.\n' * 3
big = os.urandom(307200)
gone = os.urandom(40000)
overw = os.urandom(16000)
keep = os.urandom(8192)
attrlist_data = os.urandom(40000)
child = b'child of deleted dir\n'
orphan = b'orphan content\n' * 50
sparse_len = 3 * CS

# --- $MFT (0)
mft_runs = [(MFT_CLUSTER, NREC * REC // CS)]
records[0] = make_record(0, 1, True, False, [std_info(), file_name(5, 5, '$MFT', NREC * REC, False),
                                             attr_nonres(0x80, mft_runs, NREC * REC, aid=2)])
# --- root (5)
records[5] = make_record(5, 5, True, True, [std_info(), file_name(5, 5, '.', 0, True)])
# --- $Bitmap (6)
BM_CL = 12
records[6] = make_record(6, 6, True, False, [std_info(), file_name(5, 5, '$Bitmap', len(bitmap), False),
                                             attr_nonres(0x80, [(BM_CL, 1)], len(bitmap), aid=2)])
# --- 16 hello.txt (resident)
records[16] = make_record(16, 1, True, False, [std_info(), file_name(5, 5, 'hello.txt', len(hello), False), attr_res(0x80, hello, aid=3)])
manifest['files']['/hello.txt'] = sha(hello)
# --- 17 docs (dir)
records[17] = make_record(17, 1, True, True, [std_info(), file_name(5, 5, 'docs', 0, True)])
# --- 18 docs/big.bin: three fragments, the last one *before* the second (negative run offset)
FR = [(16, 30), (600, 25), (520, 20)]
total_cl = sum(l for _, l in FR)
assert total_cl * CS >= len(big)
big_padded = big + b'\0' * (total_cl * CS - len(big))
pos = 0
for c0, ln in FR:
    put_data(c0, big_padded[pos:pos + ln * CS]); alloc(c0, ln); pos += ln * CS
records[18] = make_record(18, 1, True, False, [std_info(), file_name(17, 1, 'big.bin', len(big), False),
                                               attr_nonres(0x80, FR, len(big), aid=3)])
manifest['files']['/docs/big.bin'] = sha(big)
# --- 19 deleted gone.txt @200 (11 clusters), clusters stay free
put_data(200, gone)
records[19] = make_record(19, 2, False, False, [std_info(), file_name(5, 5, 'gone.txt', len(gone), False),
                                                attr_nonres(0x80, [(200, 11)], len(gone), aid=3)])
manifest['deleted_good'] = {'/gone.txt': sha(gone)}
# --- 20 keepme (live, clusters 100-101) and 21 deleted overwritten.bin that points at 100-103
put_data(100, keep); alloc(100, 2)
records[20] = make_record(20, 1, True, False, [std_info(), file_name(5, 5, 'keepme.bin', len(keep), False),
                                               attr_nonres(0x80, [(100, 2)], len(keep), aid=3)])
manifest['files']['/keepme.bin'] = sha(keep)
put_data(102, overw[8192:] + b'\0' * (2 * CS - len(overw[8192:])))
records[21] = make_record(21, 2, False, False, [std_info(), file_name(5, 5, 'overwritten.bin', len(overw), False),
                                                attr_nonres(0x80, [(100, 4)], len(overw), aid=3)])
manifest['deleted_damaged'] = ['/overwritten.bin']
# --- 22 file whose $DATA lives in extension record 23 (via $ATTRIBUTE_LIST)
put_data(300, attrlist_data + b'\0' * (10 * CS - len(attrlist_data))); alloc(300, 10)
def al_entry(atype, rec, start_vcn=0, name=''):
    e = u32(atype) + u16(0) + bytes([len(name), 0]) + u64(start_vcn) + u64(rec | (1 << 48)) + u16(0)
    e = e + b'\0' * (-len(e) % 8)
    return e[:4] + u16(len(e)) + e[6:]
al = al_entry(0x10, 22) + al_entry(0x30, 22) + al_entry(0x80, 23)
records[22] = make_record(22, 1, True, False, [std_info(), file_name(5, 5, 'fragmented-attrlist.dat', len(attrlist_data), False),
                                               attr_res(0x20, al, aid=4)])
records[23] = make_record(23, 1, True, False, [attr_nonres(0x80, [(300, 10)], len(attrlist_data), aid=3)], base=22 | (1 << 48))
manifest['files']['/fragmented-attrlist.dat'] = sha(attrlist_data)
# --- 24 deleted dir "olddir" (seq 3 after delete) and 25 deleted child.txt whose parent ref still says seq 2
records[24] = make_record(24, 3, False, True, [std_info(), file_name(5, 5, 'olddir', 0, True)])
records[25] = make_record(25, 1, False, False, [std_info(), file_name(24, 2, 'child.txt', len(child), False), attr_res(0x80, child, aid=3)])
manifest['deleted_good']['/olddir/child.txt'] = sha(child)
# --- 26 orphan (parent record 29 doesn't exist as a directory)
records[26] = make_record(26, 1, True, False, [std_info(), file_name(29, 1, 'orphan.txt', len(orphan), False), attr_res(0x80, orphan, aid=3)])
manifest['orphan'] = {'name': 'orphan.txt', 'sha': sha(orphan)}
# --- 27 sparse file: 3 sparse clusters, 1 real cluster, 1 sparse
real = os.urandom(CS); put_data(400, real); alloc(400, 1)
sp = b'\0' * (3 * CS) + real + b'\0' * CS
records[27] = make_record(27, 1, True, False, [std_info(), file_name(5, 5, 'sparse.bin', len(sp), False),
                                               attr_nonres(0x80, [(None, 3), (400, 1), (None, 1)], len(sp), aid=3, flags=0x8000)])
manifest['files']['/sparse.bin'] = sha(sp)
# --- 28 compressed file (should be reported unsupported)
records[28] = make_record(28, 1, True, False, [std_info(), file_name(5, 5, 'compressed.dat', 8192, False),
                                               attr_nonres(0x80, [(500, 2)], 8192, aid=3, flags=0x0001)])
manifest['unsupported'] = ['/compressed.dat']

# --- write MFT area: records 0..31, unused ones zero
for n, r in records.items():
    off = MFT_CLUSTER * CS + n * REC
    img[off:off + REC] = r
# bitmap file content
put_data(BM_CL, bytes(bitmap))

# --- boot sector (+ backup in last sector)
b = bytearray(512)
b[0:3] = b'\xEB\x52\x90'; b[3:11] = b'NTFS    '
b[11:13] = u16(BPS); b[13] = SPC; b[21] = 0xF8
b[40:48] = u64(TOTAL_SECTORS - 1)
b[48:56] = u64(MFT_CLUSTER); b[56:64] = u64(2)
b[64] = 0xF6                       # 2**10 = 1024-byte records
b[68] = 1                          # index buffer size: 1 cluster
b[72:80] = u64(0x1122334455667788)
b[510:512] = b'\x55\xAA'
img[0:512] = b
img[(TOTAL_SECTORS - 1) * BPS:TOTAL_SECTORS * BPS] = b

open(sys.argv[1], 'wb').write(img)
manifest['free_cluster_check'] = {'free': [200, 201, 210], 'allocated': [16, 100, 300]}
json.dump(manifest, open(sys.argv[2], 'w'), indent=1)
print('wrote', sys.argv[1], len(img), 'bytes')
