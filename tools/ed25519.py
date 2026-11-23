"""Ed25519 signatures in pure Python, following RFC 8032 (sections 5.1 and 6).

The build signs Pinto's release stamps and quest packs with this, and every copy of the addon
checks the signatures with src/PintoTGD/Sync/Crypto.lua. A private key is a 32-byte seed, kept
as hex text in a key file (dev only, never published).

Command line, from the project root:
  python tools/ed25519.py keygen <keyfile>                    write a new seed, print the public key
  python tools/ed25519.py pubkey <keyfile>                    print the public key
  python tools/ed25519.py sign <keyfile> <msgfile>            print the signature
  python tools/ed25519.py verify <pubhex> <msgfile> <sighex>  print ok or bad, exit 0 or 1

As a module: keygen(), publickey(seed), sign(seed, msg) and verify(pub, msg, sig), all on bytes.
Importing it has no side effects.

The arithmetic is the RFC's reference code. It isn't constant time, which is fine for signing
on the developer's own PC.
"""

import hashlib
import os
import secrets
import sys


def sha512(s):
    return hashlib.sha512(s).digest()


# Base field Z_p
p = 2**255 - 19


def modp_inv(x):
    return pow(x, p - 2, p)


# Curve constant
d = -121665 * modp_inv(121666) % p

# Group order
q = 2**252 + 27742317777372353535851937790883648493


def sha512_modq(s):
    return int.from_bytes(sha512(s), "little") % q


# Points are tuples (X, Y, Z, T) of extended coordinates, with x = X/Z, y = Y/Z, x*y = T/Z.

def point_add(P, Q):
    A, B = (P[1] - P[0]) * (Q[1] - Q[0]) % p, (P[1] + P[0]) * (Q[1] + Q[0]) % p
    C, D = 2 * P[3] * Q[3] * d % p, 2 * P[2] * Q[2] % p
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F, G * H, F * G, E * H)


# Computes s * P
def point_mul(s, P):
    Q = (0, 1, 1, 0)  # neutral element
    while s > 0:
        if s & 1:
            Q = point_add(Q, P)
        P = point_add(P, P)
        s >>= 1
    return Q


def point_equal(P, Q):
    # x1 / z1 == x2 / z2  <==>  x1 * z2 == x2 * z1
    if (P[0] * Q[2] - Q[0] * P[2]) % p != 0:
        return False
    if (P[1] * Q[2] - Q[1] * P[2]) % p != 0:
        return False
    return True


# Square root of -1
modp_sqrt_m1 = pow(2, (p - 1) // 4, p)


# Computes the x coordinate whose low bit is sign, or None if there is none (RFC 8032 5.1.3).
def recover_x(y, sign):
    if y >= p:
        return None
    # Reduced mod p here, unlike the RFC's listing: unreduced, x2 is never 0 for y = p - 1,
    # and the encoding of y = -1 with the sign bit set would decode instead of failing.
    x2 = (y * y - 1) * modp_inv(d * y * y + 1) % p
    if x2 == 0:
        if sign:
            return None
        return 0

    # Compute the square root of x2
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = x * modp_sqrt_m1 % p
    if (x * x - x2) % p != 0:
        return None

    if (x & 1) != sign:
        x = p - x
    return x


# Base point
g_y = 4 * modp_inv(5) % p
g_x = recover_x(g_y, 0)
G = (g_x, g_y, 1, g_x * g_y % p)


def point_compress(P):
    zinv = modp_inv(P[2])
    x = P[0] * zinv % p
    y = P[1] * zinv % p
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def point_decompress(s):
    if len(s) != 32:
        raise ValueError("Invalid input length for decompression")
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1

    x = recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % p)


def secret_expand(secret):
    if len(secret) != 32:
        raise ValueError("Bad size of private key")
    h = sha512(secret)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return (a, h[32:])


def publickey(seed):
    """The 32-byte public key for a 32-byte seed."""
    a, _ = secret_expand(seed)
    return point_compress(point_mul(a, G))


def sign(seed, msg):
    """The 64-byte signature of msg (bytes) under a 32-byte seed."""
    a, prefix = secret_expand(seed)
    A = point_compress(point_mul(a, G))
    r = sha512_modq(prefix + msg)
    R = point_mul(r, G)
    Rs = point_compress(R)
    h = sha512_modq(Rs + A + msg)
    s = (r + h * a) % q
    return Rs + int.to_bytes(s, 32, "little")


def verify(pub, msg, sig):
    """True if sig is a valid signature of msg under pub (RFC 8032 5.1.7, cofactorless).
    Wrong lengths, encodings that don't decode, and S >= q all give False."""
    if len(pub) != 32 or len(sig) != 64:
        return False
    A = point_decompress(pub)
    if not A:
        return False
    Rs = sig[:32]
    R = point_decompress(Rs)
    if not R:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= q:
        return False
    h = sha512_modq(Rs + pub + msg)
    sB = point_mul(s, G)
    hA = point_mul(h, A)
    return point_equal(sB, point_add(R, hA))


def keygen():
    """A new random key: (seed, public key), 32 bytes each."""
    seed = secrets.token_bytes(32)
    return seed, publickey(seed)


# Command line

USAGE = """usage:
  python tools/ed25519.py keygen <keyfile>
  python tools/ed25519.py pubkey <keyfile>
  python tools/ed25519.py sign <keyfile> <msgfile>
  python tools/ed25519.py verify <pubhex> <msgfile> <sighex>"""


def _read_seed(path):
    with open(path, "r", encoding="ascii") as f:
        seed = bytes.fromhex(f.read().strip())
    if len(seed) != 32:
        raise ValueError("%s: expected 64 hex digits (a 32-byte seed)" % path)
    return seed


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def _from_hex(text):
    try:
        return bytes.fromhex(text)
    except ValueError:
        return None


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    command, args = argv[0], argv[1:]
    try:
        if command == "keygen" and len(args) == 1:
            seed, pub = keygen()
            # O_EXCL: never overwrite an existing key file.
            fd = os.open(args[0], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="ascii") as f:
                f.write(seed.hex() + "\n")
            print(pub.hex())
            return 0
        if command == "pubkey" and len(args) == 1:
            print(publickey(_read_seed(args[0])).hex())
            return 0
        if command == "sign" and len(args) == 2:
            print(sign(_read_seed(args[0]), _read_bytes(args[1])).hex())
            return 0
        if command == "verify" and len(args) == 3:
            pub, sig = _from_hex(args[0]), _from_hex(args[2])
            msg = _read_bytes(args[1])
            good = pub is not None and sig is not None and verify(pub, msg, sig)
            print("ok" if good else "bad")
            return 0 if good else 1
    except FileExistsError:
        print("error: %s already exists; not overwriting it" % args[0], file=sys.stderr)
        return 2
    except (OSError, ValueError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 2
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
