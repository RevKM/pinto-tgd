"""Generates tools/sim/fixtures/crypto_vectors.lua: Ed25519 cross-check vectors made with
tools/ed25519.py from throwaway random keys (kept in memory only, never written anywhere)."""
import hashlib
import secrets
import sys

import os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
import ed25519 as E

OUT = os.path.join(HERE, "crypto_vectors.lua")
p, q, d, G = E.p, E.q, E.d, E.G


def enc_int(n, sign=0):
    return int.to_bytes(n | (sign << 255), 32, "little")


def secret_scalar(seed):
    return E.secret_expand(seed)[0]


# A deliberately lax verifier: reduces y mod p, accepts x = 0 with the sign bit set, and has no
# S < L check. Strictness cases must pass this one and fail the real (RFC) one, so they test
# exactly the rule they're named after.
def lax_decompress(s):
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y = (y & ((1 << 255) - 1)) % p
    x2 = (y * y - 1) * E.modp_inv(d * y * y + 1) % p
    if x2 == 0:
        x = 0
    else:
        x = pow(x2, (p + 3) // 8, p)
        if (x * x - x2) % p:
            x = x * E.modp_sqrt_m1 % p
        if (x * x - x2) % p:
            return None
        if (x & 1) != sign:
            x = p - x
    return (x, y, 1, x * y % p)


def lax_verify(pub, msg, sig):
    A, R = lax_decompress(pub), lax_decompress(sig[:32])
    if A is None or R is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    h = E.sha512_modq(sig[:32] + pub + msg)
    return E.point_equal(E.point_mul(s, G), E.point_add(R, E.point_mul(h, A)))


def flip(b, byte_index, bit):
    b = bytearray(b)
    b[byte_index] ^= 1 << bit
    return bytes(b)


cases = []


def add(name, pub, msg, sig, ok, strict_only=False):
    got = E.verify(pub, msg, sig)
    assert got == ok, (name, got, ok)
    if strict_only:
        assert not ok and lax_verify(pub, msg, sig), name
    cases.append((name, pub, msg, sig, ok))


# Random keys and messages
keys = [E.keygen() for _ in range(3)]
msgs = {n: secrets.token_bytes(n) for n in (0, 1, 64, 2000)}
signed = {}
for ki, (seed, pub) in enumerate(keys[:2], 1):
    for n in (0, 1, 64, 2000):
        sig = E.sign(seed, msgs[n])
        signed[(ki, n)] = sig
        add("key %d, %d-byte message" % (ki, n), pub, msgs[n], sig, True)
seed3, pub3 = keys[2]
for n in (2, 31, 55, 111, 112, 127, 128, 200):
    m = secrets.token_bytes(n)
    add("key 3, random %d-byte message" % n, pub3, m, E.sign(seed3, m), True)

seed1, pub1 = keys[0]

# Tampering
sig = signed[(1, 1)]
add("flipped bit in a 1-byte message", pub1, flip(msgs[1], 0, 0), sig, False)
sig = signed[(1, 64)]
add("flipped bit in a 64-byte message", pub1, flip(msgs[64], 37, 5), sig, False)
sig = signed[(1, 2000)]
add("flipped bit in the last byte of a 2000-byte message", pub1, flip(msgs[2000], 1999, 7), sig, False)
sig = signed[(1, 64)]
add("flipped bit in R (lowest bit)", pub1, msgs[64], flip(sig, 0, 0), False)
add("flipped bit in R (x sign bit)", pub1, msgs[64], flip(sig, 31, 7), False)
add("flipped bit in S (lowest bit)", pub1, msgs[64], flip(sig, 32, 0), False)
add("flipped bit in S (middle)", pub1, msgs[64], flip(sig, 52, 3), False)
add("message signed by another key", keys[1][1], msgs[64], sig, False)

# Flipped bits in the public key: one that still decodes to a point, one that doesn't
valid_flip = invalid_flip = None
for i in range(256):
    f = flip(pub1, i // 8, i % 8)
    if E.point_decompress(f) is None:
        invalid_flip = invalid_flip or (i, f)
    else:
        valid_flip = valid_flip or (i, f)
    if valid_flip and invalid_flip:
        break
add("flipped bit %d in the public key (still a point)" % valid_flip[0], valid_flip[1], msgs[64], sig, False)
add("flipped bit %d in the public key (not a point)" % invalid_flip[0], invalid_flip[1], msgs[64], sig, False)

# S >= L
R, s = sig[:32], int.from_bytes(sig[32:], "little")
add("S + L instead of S", pub1, msgs[64], R + enc_int(s + q), False, strict_only=True)
add("S = L", pub1, msgs[64], R + enc_int(q), False)
add("S = 2^256 - 1", pub1, msgs[64], R + b"\xff" * 32, False)

# Wrong lengths
add("public key of 31 bytes", pub1[:31], msgs[64], sig, False)
add("public key of 33 bytes", pub1 + b"\x00", msgs[64], sig, False)
add("signature of 63 bytes", pub1, msgs[64], sig[:63], False)
add("signature of 65 bytes", pub1, msgs[64], sig + b"\x00", False)
add("empty public key and signature", b"", msgs[64], b"", False)

# Public keys that aren't points
y = 2
while E.recover_x(y, 0) is not None:
    y += 1
add("public key y = %d: x^2 has no square root" % y, enc_int(y), msgs[64], sig, False)

# Non-canonical public keys, each with a signature a lax decoder would accept.
# y = p + 1 and (y = 1, sign set) both mean the neutral point to a lax decoder, so R = [S]B passes.
S = secrets.randbelow(q)
RB = E.point_compress(E.point_mul(S, G))
for name, pub in (("public key y = p + 1 (non-canonical neutral point)", enc_int(p + 1)),
                  ("public key y = 1 with the sign bit set (x = 0)", enc_int(1, 1))):
    add(name, pub, msgs[64], RB + enc_int(S), False, strict_only=True)
# The canonical neutral point is a valid key under RFC 8032 (no small-order check): anything
# signed as R = [S]B verifies. Pinto's key isn't such a point; this pins down the RFC behavior.
add("neutral point as public key, R = [S]B (valid per RFC 8032)", enc_int(1), msgs[64], RB + enc_int(S), True)

# y = p means y = 0 to a lax decoder: a point of order 4, so [k]A depends on k mod 4. Search for a
# signature R = [S]B - [j]A whose k is j mod 4.
pubP = enc_int(p)
A4 = lax_decompress(pubP)
while True:
    S = secrets.randbelow(q)
    for j in range(4):
        negjA = E.point_mul(j, (p - A4[0], A4[1], 1, (p - A4[0]) * A4[1] % p))
        Rj = E.point_compress(E.point_add(E.point_mul(S, G), negjA))
        k = E.sha512_modq(Rj + pubP + msgs[64])
        if k % 4 == j:
            break
    else:
        continue
    break
add("public key y = p (non-canonical)", pubP, msgs[64], Rj + enc_int(S), False, strict_only=True)

# R that isn't a point, or isn't canonical. With S = k*a mod L, [S]B - [k]A is the neutral point.
a1 = secret_scalar(seed1)
add("R is not a point", pub1, msgs[64], enc_int(y) + sig[32:], False)
for name, Rbytes, ok in (("R = neutral point (valid)", enc_int(1), True),
                         ("R = neutral point with the sign bit set (x = 0)", enc_int(1, 1), False),
                         ("R = neutral point as y = p + 1 (non-canonical)", enc_int(p + 1), False)):
    k = E.sha512_modq(Rbytes + pub1 + msgs[64])
    add(name, pub1, msgs[64], Rbytes + enc_int(k * a1 % q), ok, strict_only=not ok)

# SHA-512 of random messages
hashes = []
for n in (0, 1, 64, 111, 112, 113, 127, 128, 129, 239, 240, 2000):
    m = msgs[n] if n in msgs else secrets.token_bytes(n)
    hashes.append((m, hashlib.sha512(m).digest()))


def lua_hex(b, indent):
    h = b.hex()
    if len(h) <= 96:
        return '"%s"' % h
    parts = [h[i:i + 96] for i in range(0, len(h), 96)]
    return ("\n" + indent + ".. ").join('"%s"' % x for x in parts)


lines = []
lines.append("-- Ed25519 and SHA-512 cross-check vectors for tools/sim/test_crypto.lua, made once with")
lines.append("-- tools/ed25519.py and Python's hashlib. The keys were random throwaway keys, kept in memory")
lines.append("-- only. Everything is hex. ok is what Crypto.verify must answer. Cases whose names mention")
lines.append("-- non-canonical encodings, x = 0 or S + L were checked to pass a lax verifier, so they fail")
lines.append("-- only because of the rule they're named after. Don't edit by hand.")
lines.append("return {")
lines.append("  ed25519 = {")
for name, pub, msg, sig, ok in cases:
    lines.append("    {")
    lines.append('      name = "%s",' % name)
    lines.append("      pub = %s," % lua_hex(pub, "        "))
    lines.append("      msg = %s," % lua_hex(msg, "        "))
    lines.append("      sig = %s," % lua_hex(sig, "        "))
    lines.append("      ok = %s," % ("true" if ok else "false"))
    lines.append("    },")
lines.append("  },")
lines.append("  sha512 = {")
for m, h in hashes:
    lines.append("    {")
    lines.append("      msg = %s," % lua_hex(m, "        "))
    lines.append("      digest = %s," % lua_hex(h, "        "))
    lines.append("    },")
lines.append("  },")
lines.append("}")

with open(OUT, "w", encoding="ascii", newline="\n") as f:
    f.write("\n".join(lines) + "\n")
print("wrote %d ed25519 cases and %d sha512 cases" % (len(cases), len(hashes)))
for c in cases:
    print("  %-5s %s" % (c[4], c[0]))
