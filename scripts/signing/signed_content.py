"""Ensure signing changed only PE checksum/security directory/appended certificate.

This is NOT Authenticode verification: additionally run Test-SignedArtifact.ps1.
Inputs must be the verified unsigned bytes and the provider's exact returned PE.
Unsupported signing transformations fail closed, never relax to a filename test.
"""
import argparse
from pathlib import Path
import struct


def layout(data):
    if len(data)<256 or data[:2]!=b'MZ':
        raise ValueError('Invalid DOS header')
    pe=struct.unpack_from('<I',data,0x3c)[0]
    if pe<0x40 or pe+24>len(data) or data[pe:pe+4]!=b'PE\0\0':
        raise ValueError('Invalid PE header')
    size=struct.unpack_from('<H',data,pe+20)[0]
    opt=pe+24
    if opt+size>len(data):
        raise ValueError('Truncated optional header')
    magic=struct.unpack_from('<H',data,opt)[0]
    directory, count=(opt+112,opt+108) if magic==0x20b else ((opt+96,opt+92) if magic==0x10b else (0,0))
    if not count or count+4>opt+size or struct.unpack_from('<I',data,count)[0]<5 or directory+40>opt+size:
        raise ValueError('Missing PE security-directory slot')
    security=directory+32
    offset,length=struct.unpack_from('<II',data,security)
    return opt+64,security,offset,length


def verify_transform(unsigned, signed):
    a=unsigned.read_bytes()
    b=signed.read_bytes()
    checksum,security,old_offset,old_length=layout(a)
    new_checksum,new_security,offset,length=layout(b)
    if old_offset or old_length or (checksum,security)!=(new_checksum,new_security):
        raise ValueError('Expected unsigned baseline and identical PE layout')
    if offset<len(a) or offset>len(a)+7 or offset%8 or length<8 or offset+length!=len(b):
        raise ValueError('Unexpected appended certificate layout')
    if any(b[len(a):offset]):
        raise ValueError('Nonzero signing alignment padding')
    before=bytearray(a)
    after=bytearray(b[:len(a)])
    for start,size in [(checksum,4),(security,8)]:
        before[start:start+size]=after[start:start+size]=b'\0'*size
    if before!=after:
        raise ValueError('Signing changed code/resources/overlay')
    position=offset
    while position<offset+length:
        if position+8>len(b):
            raise ValueError('Truncated certificate header')
        size,revision,kind=struct.unpack_from('<IHH',b,position)
        if size<8 or position+size>len(b) or revision!=0x200 or kind!=2:
            raise ValueError('Unsupported WIN_CERTIFICATE')
        aligned=(size+7)&~7
        if position+aligned>len(b) or any(b[position+size:position+aligned]):
            raise ValueError('Invalid certificate alignment')
        position+=aligned
    if position!=offset+length:
        raise ValueError('Certificate table length mismatch')


if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--unsigned',required=True,type=Path)
    ap.add_argument('--signed',required=True,type=Path)
    args=ap.parse_args()
    verify_transform(args.unsigned,args.signed)
    print('PASS unchanged PE content; Authenticode/chain/timestamp verification still REQUIRED')
