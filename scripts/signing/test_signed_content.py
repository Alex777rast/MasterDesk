from pathlib import Path
import struct
import tempfile
import unittest
import signed_content as content


class SignedContentTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root=Path(self.temp.name)
        self.unsigned=root/'unsigned.exe'
        self.signed=root/'returned.exe'
        a=bytearray(512)
        a[:2]=b'MZ'
        struct.pack_into('<I',a,0x3c,0x80)
        a[0x80:0x84]=b'PE\0\0'
        struct.pack_into('<H',a,0x80+20,240)
        opt=0x80+24
        struct.pack_into('<H',a,opt,0x20b)
        struct.pack_into('<I',a,opt+108,16)
        self.security=opt+112+32
        b=bytearray(a)
        struct.pack_into('<I',b,opt+64,123)
        struct.pack_into('<II',b,self.security,len(a),16)
        # NOT a signature/certificate. Structure-only fixture is never executed
        # and cannot pass the real Windows Authenticode verifier.
        b+=struct.pack('<IHH',16,0x200,2)+b'NOTCERT!'
        self.unsigned.write_bytes(a)
        self.signed.write_bytes(b)

    def test_structural_transform_not_crypto_verification(self):
        content.verify_transform(self.unsigned,self.signed)

    def test_changed_code(self):
        b=bytearray(self.signed.read_bytes()); b[450]^=1
        self.signed.write_bytes(b)
        with self.assertRaises(ValueError): content.verify_transform(self.unsigned,self.signed)

    def test_missing_signature(self):
        self.signed.write_bytes(self.unsigned.read_bytes())
        with self.assertRaises(ValueError): content.verify_transform(self.unsigned,self.signed)

    def test_overlay_after_certificate(self):
        self.signed.write_bytes(self.signed.read_bytes()+b'changed')
        with self.assertRaises(ValueError): content.verify_transform(self.unsigned,self.signed)

    def test_previously_signed_baseline(self):
        self.unsigned.write_bytes(self.signed.read_bytes())
        with self.assertRaises(ValueError): content.verify_transform(self.unsigned,self.signed)

    def test_malformed_certificate(self):
        b=bytearray(self.signed.read_bytes()); struct.pack_into('<I',b,512,4096)
        self.signed.write_bytes(b)
        with self.assertRaises(ValueError): content.verify_transform(self.unsigned,self.signed)


if __name__=='__main__': unittest.main(verbosity=2)
